#!/bin/bash

IP="10.0.0.1"
while true; do
	st=`ifconfig tap0 2> /dev/null`
	if [ "$st" != "" ]; then
		if [[ ! "$st" =~ $IP ]]; then
			ifconfig tap0 $IP up 
			echo "Set tap0 to $IP"
		fi
	fi
	sleep 0.5
done
