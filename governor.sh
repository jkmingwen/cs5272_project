#!/bin/bash
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
dt=2 # delay between each sample
ncores_period=1
freq_period=4
cluster_period=8
output=0
counter=0

# state variables
ncores_key=0
ncores_a53=(0 0-1)
ncores_a73=(2 2-3 2-4 2-5)
ncores_vals=0
freq_key=0
cluster=1
freqs_a53=(100000 250000 500000 667000 1000000 1200000 1398000 1512000 1608000 1704000 1896000)
freqs_a73=(100000 250000 500000 667000 1000000 1200000 1398000 1512000 1608000 1704000 1800000)
freq_vals=0
policy=policy0
# state limits
freq_max=10
freq_min=0
ncores_max_a53=1
ncores_max_a73=3
ncores_max=0
ncores_min=0
# track any changes
freq_diff=0
ncores_diff=0
cluster_diff=0
governor_init=0

# Coefficients for PID (proportional, accumulated, dampening)
Kp_freq=1.5
Kp_ncores=0.9
Kp_cluster=0.4
Ki_freq=0
Ki_ncores=0
Ki_cluster=0
Kd_freq=0
Kd_ncores=0
Kd_cluster=0
freq_bias=0.4

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
update_error()
{
    update_fps ${fps_file}
    update_target ${target_file}
    error_prev=${error}
    error=$(echo "${fps_target} - ${fps_curr}" | bc)
    error_int=$(echo "(${int_prev} + ${error}) * $dt" | bc)
    error_der=$(echo "scale = 4;(${error} - ${error_prev}) / ${dt}" | bc)
    int_prev=${error_int}
}

freq_clip()
{
    [ $DEBUG -ge 2 ] && echo "freq key value to be clipped: $freq_key"
    freq_key=$(echo "scale = 0;(${freq_key} / 1)" | bc) # round to int
    [ $DEBUG -ge 2 ] && echo "freq key after rounding: $freq_key"
    if [ 1 -eq "$(echo "${freq_key} >= ${freq_max}" | bc)" ] # clip to max/min
    then
	freq_key=${freq_max}
    elif [ 1 -eq "$(echo "${freq_key} <= ${freq_min}" | bc)" ]
    then
	freq_key=${freq_min}
    fi
    [ $DEBUG -ge 2 ] && echo "freq key value after clipping: $freq_key"
}

ncores_clip()
{
    # check cluster status to set max bounds
    if [ ${cluster} -eq 1 ]
    then
	ncores_max=${ncores_max_a53}
    elif [ ${cluster} -eq 2 ]
    then
	ncores_max=${ncores_max_a73}
    fi
    [ $DEBUG -ge 2 ] && echo "ncores key value to be clipped: $ncores_key"
    # ncores_key=$(echo "scale = 0;(${ncores_key} / 1)" | bc) # round to int
    # [ $DEBUG -ge 2 ] && echo "ncores key after rounding: $ncores_key"
    if [ 1 -eq "$(echo "${ncores_key} >= ${ncores_max}" | bc)" ] # clip to max/min
    then
    	ncores_key=${ncores_max}
    elif [ 1 -eq "$(echo "${ncores_key} <= ${ncores_min}" | bc)" ]
    then
    	ncores_key=${ncores_min}
    fi
    [ $DEBUG -ge 2 ] && echo "ncores key value after clipping: $ncores_key"
}

cluster_clip()
{
    [ $DEBUG -ge 2 ] && echo "cluster value to be clipped: $cluster"
    cluster=$(echo "scale = 0;(${cluster} / 1)" | bc) # round to int
    [ $DEBUG -ge 2 ] && echo "cluster after rounding: $cluster"
    if [ 1 -eq "$(echo "${cluster} >= 1" | bc)" ]
    then
    	cluster=2
    elif [ 1 -eq "$(echo "${cluster} < 1" | bc)" ]
    then
    	cluster=1
    fi
    [ $DEBUG -ge 2 ] && echo "cluster value after clipping: $cluster"
}

freq_control()
{
    [ $DEBUG -ge 2 ] && echo "Current frequency: ${freq_vals[${freq_key}]}"
    freq_old=${freq_vals[${freq_key}]}
    freq_out=$(echo "${Kp_freq} * ${error} + ${Ki_freq} * ${error_int} + ${Kd_freq} * ${error_der} + ${freq_bias}" | bc)
    freq_key=$(echo "${freq_key} + ${freq_out}" | bc)
    freq_clip
    [ $DEBUG -ge 2 ] && echo "New frequency: ${freq_vals[${freq_key}]}"
    if [ ${freq_old} -eq ${freq_vals[${freq_key}]} ]
    then
	freq_diff=0
    else
	freq_diff=1
    fi
    [ $DEBUG -ge 3 ] && echo "Frequency change check: ${freq_diff}"
}

ncores_control()
{
    [ $DEBUG -ge 2 ] && echo "Current CPUs: ${ncores_vals[${ncores_key}]}"
    ncores_old=${ncores_vals[${ncores_key}]}
    ncores_out=$(echo "${Kp_ncores} * ${error} + ${Ki_ncores} * ${error_int} + ${Kd_ncores} * ${error_der}" | bc)
    ncores_out=$(echo "scale = 0;(${ncores_out} / 1)" | bc) # round to int
    ncores_key=$(echo "${ncores_key} + ${ncores_out}" | bc)
    ncores_clip
    [ $DEBUG -ge 2 ] && echo "New CPUs: ${ncores_vals[${ncores_key}]}"
    if [ "${ncores_old}" = "${ncores_vals[${ncores_key}]}" ]
    then
	ncores_diff=0
    else
	ncores_diff=1
    fi
    [ $DEBUG -ge 3 ] && echo "CPU change check: ${ncores_diff}"
}

cluster_control()
{
    cluster_old=${cluster}
    cluster_out=$(echo "${Kp_cluster} * ${error} + ${Ki_cluster} * ${error_int} + ${Kd_cluster} * ${error_der}" | bc)
    cluster=$(echo "${cluster} + ${cluster_out}" | bc)
    cluster_clip
    if [ $cluster_old -eq $cluster ]
    then
	cluster_diff=0
    else
	cluster_diff=1
    fi
    [ $DEBUG -ge 3 ] && echo "Cluster change check: ${cluster_diff}"
}

# whenever a cluster is changed, need to update frequency values and ncores to match
update_cluster()
{
    if [ ${cluster} -eq 1 ]
    then
	policy=policy0
	freq_vals=(${freqs_a53[*]})
	ncores_vals=(${ncores_a53[*]})
	ncores_clip # coming from cluster 2, ncores_key could be out of bounds
	echo ${freqs_a73[0]} | sudo tee /sys/devices/system/cpu/cpufreq/policy2/scaling_setspeed > tmp/log2.txt
    elif [ ${cluster} -eq 2 ]
    then
	policy=policy2
	freq_vals=(${freqs_a73[*]})
	ncores_vals=(${ncores_a73[*]})
	echo ${freqs_a53[0]} | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed > tmp/log2.txt
    fi
    # reset higher priority controllers to 0
    ncores_key=${ncores_min}
    freq_key=0
}

set_state()
{
    if [ ${governor_init} -eq 0 ]
    then
	# initialise all clusters with lowest frequency
	[ $DEBUG -ge 3 ] && echo "Setting A53 and A73 frequencies to ${freqs_a53[0]} and ${freqs_a73[0]}"
	echo ${freqs_a73[0]} | sudo tee /sys/devices/system/cpu/cpufreq/policy2/scaling_setspeed > tmp/log2.txt
	echo ${freqs_a53[0]} | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed > tmp/log2.txt
	update_cluster
    fi
    # updating cluster (determines CPU and freq values)
    if [ ${cluster_diff} -eq 1 ]
    then
	update_cluster
    fi
    echo "Setting state..."
    # update CPUs (and cluster) if there are any changes
    if [ ${ncores_diff} -eq 1 ] || [ ${cluster_diff} -eq 1 ] || [ ${governor_init} -eq 0 ]
    then
	[ $DEBUG -ge 3 ] && echo "Changes detected in new CPU/Cluster state: updating..."
	for p in /proc/${master_pid}/task/*
	do
    	    taskset -cp ${ncores_vals[$ncores_key]} ${p##*/} > tmp/log.txt
	done
    fi
    # update frequency
    if [ ${freq_diff} -eq 1 ] || [ ${cluster_diff} -eq 1 ] # freq must be set on cluster changes too
    then
	echo ${freq_vals[${freq_key}]} | sudo tee /sys/devices/system/cpu/cpufreq/${policy}/scaling_setspeed > tmp/log2.txt
    fi
}

cleanup()
{
    rm -rf tmp
}

mkdir -p tmp
trap cleanup EXIT

# initialise state with current parameters
get_pid
set_state
governor_init=1
# start governor
while :
do
    sleep ${dt}
    echo ""
    update_error
    counter=$((counter + 1))
    echo "Current iteration count: ${counter}"
    # echo "Checking mod: $((${counter} % ${freq_period}))"
    if [ "$DEBUG" -ge "1" ]; then
	echo "Current FPS is ${fps_curr}"
	echo "Target FPS is ${fps_target}"
	echo "Current error is ${error}"
	# echo "Current integral error is ${error_int}"
	# echo "Current derivative error is ${error_der}"
	echo "Previous error is ${error_prev}"
	echo "Frequency: ${freq_vals[${freq_key}]}"
	echo "CPUs: ${ncores_vals[${ncores_key}]}"
	echo "Cluster: ${cluster}"
	# echo "Previous integral error is ${int_prev}"
    fi
    [ $((counter % ${ncores_period})) -eq 0 ] && ncores_control
    [ $((counter % ${freq_period})) -eq 0 ] && freq_control
    [ $((counter % ${cluster_period})) -eq 0 ] && cluster_control
    set_state
    # reset change flags
    freq_diff=0
    ncores_diff=0
    cluster_diff=0
done
