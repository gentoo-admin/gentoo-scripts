#!/bin/bash
#
# Script to print total installed package size
# 

# SINCE="-1 day"
# SINCE="3 hour ago"
# SINCE="1 day ago"

if [ -z "$1" ] ; then
    echo Provide a time frame to search back, example: ./package-size.sh \'1 day ago\'
    exit
fi

SINCE="$1"
DATE=$(date -d "$SINCE" +%s)

if [ -z $DATE  ] ; then
    exit
fi

IFS=$'\n'
total=0
c=$(eix-installed-after -e $DATE | wc -l)
if [ $c -eq 0 ] ; then
    echo Unable to find any packages for the specified time period
    exit
fi

arr=($(equery -q size --bytes $(eix-installed-after -e $DATE)))
for a in "${arr[@]}"
do  
    package=$(echo $a | cut -d ':' -f1)
    size=$(echo $a | awk -F"[()]" '{print $6}')
    printf "%-50s%s\n" $package $(numfmt --suffix=B --to=iec-i $size)
#     echo $package: $(numfmt --suffix=B --to=iec-i $size) 
    total=$((total+size))
done

echo ========================================================
echo Total: ${#arr[@]} packages since $(date -d @$DATE '+%Y-%m-%d %H:%M:%S') size: $(numfmt --suffix=B --to=iec-i $total) 

