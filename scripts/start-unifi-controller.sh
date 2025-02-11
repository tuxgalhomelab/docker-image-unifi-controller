#!/usr/bin/env bash
set -E -e -o pipefail

unifi_lib_dir="/usr/lib/unifi"
unifi_jar="${unifi_lib_dir:?}/lib/ace.jar"
base_dir="/data/unifi-controller"
unifi_data_dir="${base_dir:?}/data"
unifi_logs_dir="${base_dir:?}/logs"
unifi_run_dir="${base_dir:?}/run"
mongodb_lock_file="${unifi_data_dir:?}/db/mongod.lock"
mongodb_port="27117"
DEFAULT_UNIFI_JVM_INIT_HEAP_SIZE_MB="1024"
DEFAULT_UNIFI_JVM_MAX_HEAP_SIZE_MB="1024"

set_umask() {
    # Configure umask to allow write permissions for the group by default
    # in addition to the owner.
    umask 0002
}

configure_system_properties() {
    local sys_prop="${unifi_data_dir:?}/system.properties"
    if [ ! -f "${sys_prop:?}" ]; then
        cat << EOF > ${sys_prop:?}
debug.device=warn
debug.mgmg=warn
debug.system=warn
debug.sdn=warn
unifi.logStdout=true
unifi.G1GC.enabled=true
unifi.db.extraargs=--quiet
unifi.xms=${UNIFI_JVM_INIT_HEAP_SIZE_MB:-$DEFAULT_UNIFI_JVM_INIT_HEAP_SIZE_MB}
unifi.xmx=${UNIFI_JVM_MAX_HEAP_SIZE_MB:-$DEFAULT_UNIFI_JVM_MAX_HEAP_SIZE_MB}
EOF
    fi
}

handle_exit() {
    echo "Exit signal received, shutting down ..."
    java -jar "${unifi_jar:?}" stop
    for i in $(seq 1 60) ; do
        if [ -z "$(pgrep -f ${unifi_jar:?})" ]; then
            echo "UniFi Network Controller Application process has exited ..."
            break
        fi

        if [ $i -gt 1 ]; then
            touch ${unifi_run_dir:?}/server.stop
        fi

        if [ $i -gt 7 ]; then
            echo "Killing UniFi Network Controller Application process ..."
            pkill -f ${unifi_jar:?} || true
        fi

        sleep 1
    done

    # shutdown mongod
    if [ -f ${mongodb_lock_file:?} ]; then
        mongo localhost:${mongodb_port:?} --eval "db.getSiblingDB('admin').shutdownServer()" >/dev/null 2>&1
    fi
    exit ${?}
}

trap_exit_signals() {
    trap 'kill ${!}; handle_exit' SIGHUP SIGINT SIGQUIT SIGTERM
}

start_unifi_controller() {
    echo "Starting UniFi Network Controller ..."
    echo

    trap_exit_signals
    configure_system_properties

    pushd ${base_dir:?}
    java \
        -Dfile.encoding=UTF-8 \
        -Djava.awt.headless=true \
        -Dapple.awt.UIElement=true \
        -Dunifi.core.enabled=false \
        -Dunifi.mongodb.service.enabled=false \
        -Dunifi.datadir=${unifi_data_dir:?} \
        -Dunifi.logdir=${unifi_logs_dir:?} \
        -Dunifi.rundir=${unifi_run_dir:?} \
        -XX:ErrorFile=${base_dir:?}/logs/unifi_crash.log \
        -Xlog:gc:logs/gc.log:time:filecount=10,filesize=20M \
        -Xms${UNIFI_JVM_INIT_HEAP_SIZE_MB:-$DEFAULT_UNIFI_JVM_INIT_HEAP_SIZE_MB}M \
        -Xmx${UNIFI_JVM_MAX_HEAP_SIZE_MB:-$DEFAULT_UNIFI_JVM_MAX_HEAP_SIZE_MB}M \
        -XX:+UseParallelGC \
        -XX:+ExitOnOutOfMemoryError \
        -XX:+CrashOnOutOfMemoryError \
        --add-opens java.base/java.lang=ALL-UNNAMED \
        --add-opens java.base/java.time=ALL-UNNAMED \
        --add-opens java.base/sun.security.util=ALL-UNNAMED \
        --add-opens java.base/java.io=ALL-UNNAMED \
        --add-opens java.rmi/sun.rmi.transport=ALL-UNNAMED \
        -jar ${unifi_jar:?} start &
    wait
    echo "WARN: UniFi Network Controller Application process terminated without being signaled!"
}

set_umask
start_unifi_controller
