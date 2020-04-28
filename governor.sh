#!/bin/sh
DEBUG=$1
fps_file="fps.txt"
target_file="target_fps.txt"

fps_curr=0
fps_target=0
error_prev=0
int_prev=0
error=0
error_int=0
error_der=0
dt=5 # delay between each sample
output=0
counter=0

# Coefficients for PID (proportional, accumulated, dampening)
Kp=1
Ki=0
Kd=0

get_pid()
{
    master_pid="$(pgrep -x DisplayImage)"
}

# Read current FPS reading
update_fps()
{
    while read f
    do
	fps_curr=${f}
    done < $1
}

# Read target FPS reading
update_target()
{
    while read f
    do
	fps_target=${f}
    done < $1
}

# Updates FPS values and recalculates output value
update_output()
{
    update_fps ${fps_file}
    update_target ${target_file}
    error=$(echo "${fps_target} - ${fps_curr}" | bc)
    error_int=$(echo "(${int_prev} + ${error}) * $dt" | bc)
    error_der=$(echo "scale = 4;(${error} - ${error_prev}) / ${dt}" | bc)
    error_prev=${error}
    int_prev=${error_int}
    output=$(echo "${Kp} * ${error} + ${Ki} * ${error_int} + ${Kd} * ${error_der}" | bc)
}

# Args: cluster (0/2) and frequency (int), updates cluster CPU freq
set_freq()
{
}

# Args: master PID and cluster (0/2), migrates taskset to specified cluster
set_cluster()
{
}

# Args: cluster, increases number of cores
inc_ncores()
{
}

# Args: cluster, decreases number of cores
dec_ncores()
{
}

dvfs_control()
{
    update_output
    # if output -ve, +freq and vice versa
}

core_control()
{
    update_output
    # if output -ve, +ncores and vice versa
}

cluster_control()
{
    update_output
    # if output -ve, migrate to bigger core vice versa
}

trap "exit" INT
get_pid
while :
do    
    update_output
    if [ "$DEBUG" -eq "1" ]; then
	echo "Current FPS is ${fps_curr}"
	echo "Target FPS is ${fps_target}"
	echo "Current error is ${error}"
	echo "Current integral error is ${error_int}"
	echo "Current derivative error is ${error_der}"
	echo "Previous error is ${error_prev}"
	echo "Previous integral error is ${int_prev}"
	echo "Output is ${output}"
	echo ""
    fi
    sleep ${dt}
done

