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
dt=5 # delay between each sample
output=0
counter=0

# state variables
ncores_a53=2
ncores_a73=4
freq_key=1
cluster=1
freqs_a53=(100000 250000 500000 667000 1000000 1200000 1398000 1512000 1608000 1704000 1896000)
freqs_a73=(100000 250000 500000 667000 1000000 1200000 1398000 1512000 1608000 1704000 1800000)
freq_vals=0
policy=policy0
# state limits
freq_max=10
freq_min=0
ncores_max_a53=2
ncores_max_a73=4
ncores_min=1

# Coefficients for PID (proportional, accumulated, dampening)
Kp_freq=1
Kp_ncores=1
Kp_cluster=1
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
    [ $DEBUG -eq 1 ] && echo "freq value to be clipped: $freq_key"
    freq_key=$(echo "scale = 0;(${freq_key} / 1)" | bc) # round to int
    [ $DEBUG -eq 1 ] && echo "freq after rounding: $freq_key"
    if [ 1 -eq "$(echo "${freq_key} >= ${freq_max}" | bc)" ] # clip to max/min
    then
	freq_key=${freq_max}
    elif [ 1 -eq "$(echo "${freq_key} <= ${freq_min}" | bc)" ]
    then
	freq_key=${freq_min}
    fi
    [ $DEBUG -eq 1 ] && echo "freq value after clipping: $freq_key"
}

ncores_clip()
{
    # # [ $DEBUG -eq 1 ] && echo "freq value to be clipped: $ncores_a53"
    # freq_key=$(echo "scale = 0;(${freq_key} / 1)" | bc) # round to int
    # # [ $DEBUG -eq 1 ] && echo "freq after rounding: $freq_key"
    # if [ 1 -eq "$(echo "${freq_key} >= ${freq_max}" | bc)" ] # clip to max/min
    # then
    # 	freq_key=${freq_max}
    # elif [ 1 -eq "$(echo "${freq_key} <= ${freq_min}" | bc)" ]
    # then
    # 	freq_key=${freq_min}
    # fi
    # # [ $DEBUG -eq 1 ] && echo "freq value after clipping: $freq_key"
    return
}

freq_control()
{
    # if counter % freq_period, then output = 0 else:
    [ $DEBUG -eq 1 ] && echo "Current frequency: ${freqs_a53[${freq_key}]}"
    freq_out=$(echo "${Kp_freq} * ${error} + ${Ki_freq} * ${error_int} + ${Kd_freq} * ${error_der}" | bc)
    freq_key=$(echo "${freq_key} + ${freq_out}" | bc)
    freq_clip
    [ $DEBUG -eq 1 ] && echo "New frequency: ${freqs_a53[${freq_key}]}"
}

ncores_control()
{
    # ncores_out=$(echo "${Kp_ncores} * ${error} + ${Ki_ncores} * ${error_int} + ${Kd_ncores} * ${error_der}" | bc)
    # ncores_a53=$(echo "${ncores_a53} + ${ncores_out}" | bc)
    # ncores_clip
    return
}

cluster_control()
{
    update_error
    # if output -ve, migrate to bigger core vice versa
}

set_state()
{
    # update frequency
    if [ ${cluster} -eq 1 ]
    then
	echo "Cluster is equal to ${cluster}"
	policy=policy0
	freq_vals=(${freqs_a53[*]})
    elif [ ${cluster} -eq 2 ]
    then
	echo "Cluster is equal to ${cluster}"
	policy=policy2
	freq_vals=(${freqs_a73[*]})
    fi

    echo "Setting state..."
    # echo "Frequency to set is ${freq_vals[${freq_key}]}, policy is ${policy}"
    echo ${freq_vals[${freq_key}]} | sudo tee /sys/devices/system/cpu/cpufreq/${policy}/scaling_setspeed
    # sudo bash -c 'echo' ${freq_vals[${freq_key}]} > /sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed
}

trap "exit" INT
# initialise state
get_pid
## set cluster and number of cores
for p in /proc/${master_pid}/task/*
do
    taskset -cp 0-1 ${p##*/}
done
## set frequency
sudo bash -c 'echo 100000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed'

while :
do
    sleep ${dt}
    update_error
    counter=$((counter + 1))
    # echo "Current count is ${counter}"
    # echo "Checking mod: $((counter % 5))"
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
    freq_control
    set_state
done

