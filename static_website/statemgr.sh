#!/bin/bash

# naming is all from server perspective: local == server
local_ip=10.0.0.2
local_port=80
dest_ip=10.0.0.1
state_fn=state.dat

if [ $# -eq 0 ]; then
	echo "Usage: $0 <cmd:get,set,getset> [client_port (if get|getset), state_file (if set)]"
	exit
fi
cmd=$1

echo "## connections to server:"
netstat -na | grep $local_ip:$local_port

# arg: client port number
if [ $# -gt 1 ]; then
	if [[ "$cmd" =~ "get" ]]; then
		dest_port=$2
	else
		state_fn=$2
	fi
else
	# pick the last (perhaps recent) established connection
	established_conn=`netstat -na | grep $local_ip:$local_port | grep ESTABLISHED | tail -1`
	dest=`echo $established_conn | awk '{print $4}'`
	dest_ip=`echo $dest | cut -d: -f1` 
	dest_port=`echo $dest | cut -d: -f2` 
fi

id_sexp_str="GET((dest_port%20$dest_port)(dest_ip%20$dest_ip)(local_port%20$local_port)(local_ip%20$local_ip))"

echo "## client:$dest_ip:$dest_port <-> server:$local_ip:$local_port" 
if [[ "$cmd" =~ "get" ]]; then
	echo "## id_sexp_str:$id_sexp_str" 
	echo "## get state result:"
	wget -q -O $state_fn $local_ip/$id_sexp_str
	[ "$cmd" = "get" ] && cat $state_fn
	echo
fi
if [[ "$cmd" =~ "set" ]]; then
	if [ ! -e $state_fn ]; then
		echo "Error: $state_fn not found"
		exit
	fi
	wget -q -O - "$local_ip/SET" --post-file=$state_fn
fi
echo
