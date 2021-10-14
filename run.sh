#!/bin/bash

dir=$(dirname $(readlink -f "$0"))
cd $dir
echo "pull /system/framework/services.jar"
adb pull /system/framework/services.jar
echo "backup services.jar to services_bak.jar"
cp services.jar services_bak.jar

echo "unzip services.jar to ./services dir"
rm -rf services
unzip services.jar -d services &>/dev/null

dex=$(grep -lr "has no signatures that match those in shared user" services)
echo "need modify file: $dex"
echo "dex2smali to ./out dir"
rm -rf out
java -jar baksmali-2.5.2.jar d $dex

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

echo "smali2dex to ./out.dex file"
java -jar smali-2.5.2.jar a out
echo "move ./out.dex to $dex file"
mv out.dex $dex

echo "re tar ./services ./services.jar file"
# 也可以归档管理器直接打开，不解压替换classes2.dex
jar cvfm services.jar services/META-INF/MANIFEST.MF -C services/ . &>/dev/null

echo "push ./services.jar file"
adb wait-for-device root
adb remount
adb push services.jar /system/framework/services.jar
adb reboot
cd -
