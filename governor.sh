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
ncores_period=4
freq_period=1
cluster_period=7
output=0
counter=0

# state variables
ncores_key=1
ncores_a53=(0 0-1)
ncores_a73=(2 2-3 2-4 2-5)
ncores_vals=0
freq_key=1
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

# Coefficients for PID (proportional, accumulated, dampening)
Kp_freq=1
Kp_ncores=0.5
Kp_cluster=0.4
Ki_freq=0
Ki_ncores=0
Ki_cluster=0
Kd_freq=0
Kd_ncores=0
Kd_cluster=0

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
    error=$(echo "${fps_target} - ${fps_curr}" | bc)
    error_int=$(echo "(${int_prev} + ${error}) * $dt" | bc)
    error_der=$(echo "scale = 4;(${error} - ${error_prev}) / ${dt}" | bc)
    error_prev=${error}
    int_prev=${error_int}
}

freq_clip()
{
    # [ $DEBUG -eq 1 ] && echo "freq value to be clipped: $freq_key"
    freq_key=$(echo "scale = 0;(${freq_key} / 1)" | bc) # round to int
    # [ $DEBUG -eq 1 ] && echo "freq after rounding: $freq_key"
    if [ 1 -eq "$(echo "${freq_key} >= ${freq_max}" | bc)" ] # clip to max/min
    then
	freq_key=${freq_max}
    elif [ 1 -eq "$(echo "${freq_key} <= ${freq_min}" | bc)" ]
    then
	freq_key=${freq_min}
    fi
    # [ $DEBUG -eq 1 ] && echo "freq value after clipping: $freq_key"
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
    [ $DEBUG -eq 1 ] && echo "ncores key value to be clipped: $ncores_key"
    ncores_key=$(echo "scale = 0;(${ncores_key} / 1)" | bc) # round to int
    [ $DEBUG -eq 1 ] && echo "ncores key after rounding: $ncores_key"
    if [ 1 -eq "$(echo "${ncores_key} >= ${ncores_max}" | bc)" ] # clip to max/min
    then
    	ncores_key=${ncores_max}
    elif [ 1 -eq "$(echo "${ncores_key} <= ${ncores_min}" | bc)" ]
    then
    	ncores_key=${ncores_min}
    fi
    [ $DEBUG -eq 1 ] && echo "ncores key value after clipping: $ncores_key"
}

cluster_clip()
{
    [ $DEBUG -ge 1 ] && echo "cluster value to be clipped: $cluster"
    cluster=$(echo "scale = 0;(${cluster} / 1)" | bc) # round to int
    [ $DEBUG -ge 1 ] && echo "cluster after rounding: $cluster"
    if [ 1 -eq "$(echo "${cluster} > 1" | bc)" ]
    then
    	cluster=2
    elif [ 1 -eq "$(echo "${cluster} <= 1" | bc)" ]
    then
    	cluster=1
    fi
    [ $DEBUG -ge 1 ] && echo "cluster value after clipping: $cluster"
}

freq_control()
{
    # [ $DEBUG -eq 1 ] && echo "Current frequency: ${freqs_a53[${freq_key}]}"
    freq_out=$(echo "${Kp_freq} * ${error} + ${Ki_freq} * ${error_int} + ${Kd_freq} * ${error_der}" | bc)
    freq_key=$(echo "${freq_key} + ${freq_out}" | bc)
    freq_clip
    # [ $DEBUG -eq 1 ] && echo "New frequency: ${freqs_a53[${freq_key}]}"
}

ncores_control()
{
    # [ $DEBUG -eq 1 ] && echo "Current CPUs: ${ncores_vals[${ncores_key}]}"
    ncores_out=$(echo "${Kp_ncores} * ${error} + ${Ki_ncores} * ${error_int} + ${Kd_ncores} * ${error_der}" | bc)
    ncores_key=$(echo "${ncores_key} + ${ncores_out}" | bc)
    ncores_clip
    # [ $DEBUG -eq 1 ] && echo "New CPUs: ${ncores_vals[${ncores_key}]}"
}

cluster_control()
{
    cluster_out=$(echo "${Kp_cluster} * ${error} + ${Ki_cluster} * ${error_int} + ${Kd_cluster} * ${error_der}" | bc)
    cluster=$(echo "${cluster} + ${cluster_out}" | bc)
    cluster_clip
}

set_state()
{
    if [ ${cluster} -eq 1 ]
    then
	policy=policy0
	freq_vals=(${freqs_a53[*]})
	ncores_vals=(${ncores_a53[*]})
    elif [ ${cluster} -eq 2 ]
    then
	policy=policy2
	freq_vals=(${freqs_a73[*]})
	ncores_vals=(${ncores_a73[*]})
    fi

    echo "Setting state..."
    # update CPUs
    for p in /proc/${master_pid}/task/*
    do
    	taskset -cp ${ncores_vals[$ncores_key]} ${p##*/}
    done
    # update frequency
    if [ $((counter % ${freq_period})) -eq 0 ]; then
	echo ${freq_vals[${freq_key}]} | sudo tee /sys/devices/system/cpu/cpufreq/${policy}/scaling_setspeed
    fi
    # updating cluster is done implicitly
}

trap "exit" INT
# initialise state with current parameters
get_pid
set_state

while :
do
    sleep ${dt}
    update_error
    counter=$((counter + 1))
    echo "Current count is ${counter}"
    # echo "Checking mod: $((${counter} % ${freq_period}))"
    if [ "$DEBUG" -eq "1" ]; then
	echo "Current FPS is ${fps_curr}"
	echo "Target FPS is ${fps_target}"
	echo "Current error is ${error}"
	# echo "Current integral error is ${error_int}"
	# echo "Current derivative error is ${error_der}"
	echo "Previous error is ${error_prev}"
	# echo "Previous integral error is ${int_prev}"
	# echo ""
    fi
    [ $((counter % ${ncores_period})) -eq 0 ] && ncores_control
    [ $((counter % ${freq_period})) -eq 0 ] && freq_control
    [ $((counter % ${cluster_period})) -eq 0 ] && cluster_control
    set_state
done

