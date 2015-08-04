#!/bin/bash

if [ -z "$ASSETSOURCE" ]; then
    export ASSETSOURCE="http://lab1.snabb.co:2008/~max/test_env"
    echo "Defaulting to ASSETSOURCE=$ASSETSOURCE"
fi

if [ -z "$MAC" ]; then
    export MAC=52:54:00:00:00:
    echo "Defaulting to MAC=$MAC"
fi

if [ -z "$IP" ]; then
    export IP=fe80::5054:ff:fe00:
    echo "Defaulting to IP=$IP"
fi

if [ -z "$GUEST_MEM" ]; then
    export GUEST_MEM=512
    echo "Defaulting to GUEST_MEM=$GUEST_MEM"
fi

if [ -z "$HUGETLBFS" ]; then
    export HUGETLBFS=/hugetlbfs
    echo "Defaulting to HUGETLBFS=$HUGETLBFS"
fi

#calculate and set qemu_mq related variables
if [ -n "$QUEUES" ]; then
    export qemu_mq=on
else
    export qemu_mq=off
    export QUEUES=1
    echo "Defaulting to QUEUES=$QUEUES"
fi
export qemu_smp=$QUEUES
export qemu_vectors=$((2*$QUEUES + 1))

export sockets=""
export assets=$HOME/.test_env
export qemu=qemu/obj/x86_64-softmmu/qemu-system-x86_64

export tmux_session=""

function tmux_launch {
    command="$2 2>&1 | tee $3"
    if [ -z "$tmux_session" ]; then
        tmux_session=test_env-$$
        tmux new-session -d -n "$1" -s $tmux_session "$command"
    else
        tmux new-window -a -d -n "$1" -t $tmux_session "$command"
    fi
}

export snabb_n=0

function pci_node {
    case "$1" in
        *:*:*.*)
            cpu=$(cat /sys/class/pci_bus/${1%:*}/cpulistaffinity | cut -d "-" -f 1)
            numactl -H | grep "cpus: $cpu" | cut -d " " -f 2
            ;;
        *)
            echo $1
            ;;
    esac
}

function snabb_log {
    echo "snabb${snabb_n}.log"
}

function snabb {
    tmux_launch \
        "snabb$snabb_n" \
        "numactl --cpunodebind=$(pci_node $1) --membind=$(pci_node $1) ./snabb $2" \
        $(snabb_log)
    snabb_n=$(expr $snabb_n + 1)
}

export qemu_n=0

function qemu_log {
    echo "qemu${qemu_n}.log"
}

function qemu_image {
    image=$assets/$1${qemu_n}.img
    [ -f $image ] || cp $assets/$1.img $image
    echo $image
}

function provide_qemu {
    if ! [ -d $assets/qemu ]; then
        mkdir -p $assets
        echo "Fetching qemu source code:"
        (cd $assets
            wget "$ASSETSOURCE/qemu.tar.gz" \
                && tar xzf qemu.tar.gz \
                && rm qemu.tar.gz
        ) || return 1
    fi
    echo "Building qemu:"
    (cd $assets/qemu
        mkdir obj; cd obj
        ../configure --target-list=x86_64-softmmu && make -j4)
}

function provide_file {
    mkdir -p $assets
    echo "Fetching $1:"
    (cd $assets
        wget "$ASSETSOURCE/$1")
}

function provide_file_gz {
    provide_file $1.gz && gunzip $assets/$1.gz
}

function mac {
    printf "$MAC%02X\n" $1
}

function ip {
    printf "$IP%04X\n" $1
}

function launch_qemu {
    if [ ! -n $QUEUES ]; then
        export mqueues=",queues=$QUEUES"
    fi
    tmux_launch \
        "qemu$qemu_n" \
        "numactl --cpunodebind=$(pci_node $1) --membind=$(pci_node $1) \
        $assets/$qemu \
        -kernel $assets/$4 \
        -append \"earlyprintk root=/dev/vda rw console=ttyS0 ip=$(ip $qemu_n)\" \
        -m $GUEST_MEM -numa node,memdev=mem -object memory-backend-file,id=mem,size=${GUEST_MEM}M,mem-path=$HUGETLBFS,share=on \
        -netdev type=vhost-user,id=net0,chardev=char0${mqueues} -chardev socket,id=char0,path=$2,server \
        -device virtio-net-pci,netdev=net0,mac=$(mac $qemu_n),mq=$qemu_mq,vectors=$qemu_vectors \
        -M pc -smp $qemu_smp -cpu host --enable-kvm \
        -serial telnet:localhost:$3,server,nowait \
        -drive if=virtio,file=$(qemu_image $5) \
        -nographic" \
        $(qemu_log)
    qemu_n=$(expr $qemu_n + 1)
    sockets="$sockets $2"
}

function qemu {
    [ -f $assets/$qemu ]    || provide_qemu             || return 1
    [ -f $assets/bzImage ]  || provide_file bzImage     || return 1
    [ -f $assets/qemu.img ] || provide_file_gz qemu.img || return 1
    launch_qemu $1 $2 $3 bzImage qemu
}

function packetblaster {
    [ -f $assets/$2.pcap ] || provide_file $2.pcap || return 1
    snabb $1 "packetblaster replay $assets/$2.pcap $1"
}

function qemu_dpdk {
    [ -f $assets/$qemu ]                 || provide_qemu                       || return 1
    [ -f $assets/bzImage-no-virtio-net ] || provide_file bzImage-no-virtio-net || return 1
    [ -f $assets/qemu-dpdk.img ]         || provide_file_gz qemu-dpdk.img      || return 1
    launch_qemu $1 $2 $3 bzImage-no-virtio-net qemu-dpdk
}

function snabbnfv_bench {
    numactl --cpunodebind=$(pci_node $1) --membind=$(pci_node $1) \
        ./snabb snabbnfv traffic -B $2 $1 \
        program/snabbnfv/test_fixtures/nfvconfig/test_functions/snabbnfv-bench1.port \
        vhost_%s.sock
}

function on_exit {
    [ -n "$tmux_session" ] && tmux kill-session -t $tmux_session 2>&1 >/dev/null
    rm -f $sockets
    exit
}

trap on_exit EXIT HUP INT QUIT TERM
