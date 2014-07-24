#!/bin/bash

# naming is all from server perspective: local == server
local_ip=10.0.0.2
local_port=80
dest_ip=10.0.0.1

# arg: client port number
if [ $# -eq 1 ]; then
	dest_port=$1
else
	# pick the last (perhaps recent) established connection
	established_conn=`netstat -na | grep $local_ip:$local_port | grep ESTABLISHED | tail -1`
	dest=`echo $established_conn | awk '{print $4}'`
	echo "established_conn=$established_conn"
	dest_ip=`echo $dest | cut -d: -f1` 
	dest_port=`echo $dest | cut -d: -f2` 
fi

id_sexp_str="((dest_port%20$dest_port)(dest_ip%20$dest_ip)(local_port%20$local_port)(local_ip%20$local_ip))"

echo "## client:$dest <-> server:$local_ip:$local_port" 
echo "## id_sexp_str:$id_sexp_str" 
echo "## state:"
wget -q -O - $local_ip/$id_sexp_str
echo
