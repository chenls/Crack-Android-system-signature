# 在有root权限下破解Android系统签名，安装未系统签名的APK

## 前言

本文提到的相关工具和脚本同步在此：[git@github.com:chenls/Crack-Android-system-signature.git](git@github.com:chenls/Crack-Android-system-signature.git)

在需要使用一些系统层面的API时（如：HIDL服务），我们APK中必须在应用程序的``AndroidManifest.xml`中的`manifest`节点中加入`android:sharedUserId="android.uid.system"`属性，在添加此属性后，往往需要使用Android源码编译或者使用对应的签名文件对APK签名，才能正常安装。

若未使用系统签名时，安装会报如下错误：

```bash
$ adb install outputtxBJV3_double.apk 
Performing Streamed Install
adb: failed to install outputtxBJV3_double.apk: Failure [INSTALL_FAILED_SHARED_USER_INCOMPATIBLE: Reconciliation failed...: Reconcile failed: Package com.example.test has no signatures that match those in shared user android.uid.system; ignoring!]
```

对应的logcat log如下：

```
04-15 16:38:35.099  1716  1815 W PackageManager: com.android.server.pm.PackageManagerService$ReconcileFailure: Reconcile failed: Package com.example.test has no signatures that match those in shared user android.uid.system; ignoring!
04-15 16:38:35.099  1716  1815 W PackageManager: 	at com.android.server.pm.PackageManagerService.reconcilePackagesLocked(PackageManagerService.java:16974)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at com.android.server.pm.PackageManagerService.installPackagesLI(PackageManagerService.java:17366)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at com.android.server.pm.PackageManagerService.installPackagesTracedLI(PackageManagerService.java:16693)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at com.android.server.pm.PackageManagerService.lambda$processInstallRequestsAsync$22$PackageManagerService(PackageManagerService.java:14770)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at com.android.server.pm.-$$Lambda$PackageManagerService$9znobjOH7ab0F1jsW2oFdNipS-8.run(Unknown Source:6)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at android.os.Handler.handleCallback(Handler.java:938)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at android.os.Handler.dispatchMessage(Handler.java:99)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at android.os.Looper.loop(Looper.java:236)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at android.os.HandlerThread.run(HandlerThread.java:67)
04-15 16:38:35.099  1716  1815 W PackageManager: 	at com.android.server.ServiceThread.run(ServiceThread.java:45)
```

从log中，我们看到在安装APK时，`PackageManagerService.java`中抛出了异常。我们可以对出错的地方进行修改，从而破解Android系统签名，直接安装未系统签名的APK，接下来看看具体如何操作吧！

## 思路

总共分为7个步骤：
1. 通过Android源码找到`PackageManagerService.java`最终编译出来对应到设备的文件，也就是`/system/framework/services.jar`；
2. 从设备中pull出`services.jar`，提取`services.jar`中的`classes.dex`的文件；
3. 使用`baksmali`工具将`classes.dex`转成smali文件；
4. 修改smali文件中验证签名时报错的代码；
5. 使用`smali`工具将smali文件转回dex文件；
6. 将修改后的dex文件，重新打包成`services.jar`；
7. push修改后的`services.jar`到设备，然后重启，此时就可以直接安装未系统签名的APK了。

## 过程

### 查看android源码

根据报错信息`"has no signatures that match those in shared user"`我们可以查到对应的源码[PackageManagerServiceUtils.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-mainline-11.0.0_r5/services/core/java/com/android/server/pm/PackageManagerServiceUtils.java);
通过源码位置，我们倒推查看编译脚本。[services/core/Android.bp](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-mainline-11.0.0_r5/services/core/Android.bp) 中编译了`PackageManagerServiceUtils.java`文件，生成`services.core` library，[services/Android.bp](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-mainline-11.0.0_r5/services/Android.bp) 中依赖了`services.core` library，生成`services` library，也就是`services.jar`，对应到设备中`/system/framework/services.jar`文件。

我们要想对其原有逻辑修改，可以直接修改Android原生源码，编译后再push到设备中验证，但是由于一般的厂家都会对Android原生源码进行定制，导致源码不匹配。所以我们只能将设备当前的`/system/framework/services.jar`文件pull出来对其修改后，再push到原设备（注意此处需要root权限），以此保证其兼容性。

pull services.jar文件，并解压：

```bash
echo "pull /system/framework/services.jar"
adb pull /system/framework/services.jar
echo "backup services.jar to services_bak.jar"
cp services.jar services_bak.jar

echo "unzip services.jar to ./services dir"
rm -rf services
unzip services.jar -d services &>/dev/null
```

### 解压services.jar得到classes.dex

查看services文件夹内容，其中有两个dex文件：

```bash
$ tree services
services
├── classes2.dex
├── classes.dex
├── com
│   └── ...
└── META-INF
    └── MANIFEST.MF

12 directories, 12 files
```

根据报错信息，查找我们要修改源码对应的dex文件：

```bash
$ tree 
dex=$(grep -lr "has no signatures that match those in shared user" services)
echo "need modify file: $dex"
```

### baksmali反编译

jar工具包：smali和baksmali，下载地址：[https://bitbucket.org/JesusFreke/smali/downloads/](https://bitbucket.org/JesusFreke/smali/downloads/)，此处我们使用目前最新版本：2.5.2。

使用baksmali-2.5.2.jar反编译dex得到smali文件：

```bash
echo "dex2smali to ./out dir"
rm -rf out
java -jar baksmali-2.5.2.jar d $dex
```

### 修改smali文件

[PackageManagerServiceUtils.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-mainline-11.0.0_r5/services/core/java/com/android/server/pm/PackageManagerServiceUtils.java)的源码：

```java
public static boolean verifySignatures(PackageSetting pkgSetting,
            PackageSetting disabledPkgSetting, PackageParser.SigningDetails parsedSignatures,
            boolean compareCompat, boolean compareRecover)
            throws PackageManagerException {
    ...
    // line:689
    if (!match) {
        throw new PackageManagerException(INSTALL_FAILED_SHARED_USER_INCOMPATIBLE,
                "Package " + packageName
                + " has no signatures that match those in shared user "
                + pkgSetting.getSharedUser().name + "; ignoring!");
    }
    ...
    // line:725
    if (!parsedSignatures.hasCommonAncestor(
            pkgSetting.getSharedUser().signatures.mSigningDetails)) {
        throw new PackageManagerException(INSTALL_FAILED_SHARED_USER_INCOMPATIBLE,
                "Package " + packageName + " has a signing lineage "
                        + "that diverges from the lineage of the sharedUserId");
    }
    ...
}
```

我们可以直接修改`verifySignatures()`方法中如上两个if处，使其条件不成立，从而不会抛出异常。

对应到的smali代码，将if-eqz改成if-nez ，即将if==0 改成 if!=0：

```smali
    .line 725
    invoke-virtual {p2, v5}, Landroid/content/pm/PackageParser$SigningDetails;->hasCommonAncestor(Landroid/content/pm/PackageParser$SigningDetails;)Z

    move-result v5

    if-eqz v5, :cond_16f // 将其改成if-nez v2, :cond_16f，即将if==0 改成 if!=0

    goto :goto_1b1

    .line 727
    :cond_16f

    ...

    const-string v3, " has a signing lineage that diverges from the lineage of the sharedUserId"

    ...

    invoke-direct {v5, v4, v3}, Lcom/android/server/pm/PackageManagerException;-><init>(ILjava/lang/String;)V

    throw v5

    ...



    .line 689
    :cond_105
    const/4 v4, -0x8

    if-eqz v2, :cond_189 // 将其改成if-nez v2, :cond_189 ，即将if==0 改成 if!=0

    ...

    :cond_189
    new-instance v5, Lcom/android/server/pm/PackageManagerException;

    ...

    const-string v3, " has no signatures that match those in shared user "

    invoke-virtual {v6, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
```

smali相关语法可参考：[Smali基础语法总结](https://www.cnblogs.com/bmjoker/p/10506623.html)。

对应bash修改脚本：

```bash
modify() {
    # 文件和行号
    file_and_line=$(grep -nr "$1" out)
    if [ -n "$file_and_line" ]; then
        # 文件
        file=$(echo $file_and_line | awk -F ":" '{print $1}')
        # 行号
        line_e=$(echo $file_and_line | awk -F ":" '{print $2}')
        # 倒推30行
        let "line_s=line_e-30"
        # 部分内容
        # cat $file | head -n $line_e | tail -n +$line_s
        modify_content=$(cat $file | head -n $line_e | tail -n +$line_s | grep ':cond_' | tail -1)
        # 需要修改的所在行号
        modify_content_str=$(grep -n $modify_content $file)
        modify_content_line=$(echo $modify_content_str | awk -F ":" '{print $1}')
        # 进行修改
        sed -i "${modify_content_line}s/if-eqz/if-nez/g" $file
        echo "$file:$modify_content_line  modify 'if-eqz --> if-nez'"
    else
        echo "!!! not found: $1"
    fi
}

modify "has no signatures that match those in shared user"
modify "has a signing lineage that diverges from the lineage of the sharedUserId"
```

### smali编译

将修改后的smali文件，编译成dex文件：

```bash
echo "smali2dex to ./out.dex file"
java -jar smali-2.5.2.jar a out
echo "move ./out.dex to $dex file"
mv out.dex $dex
```
### 重新打包jar

将修改后的classes.dex，打包成jar：

```bash
echo "re tar ./services ./services.jar file"
# 也可以归档管理器直接打开，不解压替换classes2.dex
jar cvfm services.jar services/META-INF/MANIFEST.MF -C services/ . &>/dev/null
```

### push services.jar并重启

将修改后的services.jar push到设备并重启：

```bash
echo "push ./services.jar file"
adb wait-for-device root
adb remount
adb push services.jar /system/framework/services.jar
adb reboot
```
## 总结

在有root权限情况下，我们通过`smali`相关工具反编译`services.jar`后，对其修改后，达到了直接安装需要系统签名的APK。