#!@shell@
# systemd-detect-virt - print the kind of virtualisation we run in, if any.

PATH=@path@:$PATH
RUNTIME=@runtime@

want=any quiet=0
for a in "$@"; do
  case $a in
    -c|--container) want=container ;;
    -v|--vm) want=vm ;;
    -q|--quiet) quiet=1 ;;
    -r|--chroot) [[ $(stat -c %d:%i /) != $(stat -c %d:%i /proc/1/root/. 2>/dev/null) ]]; exit $? ;;
    --private-users|--cvm) exit 1 ;;
    --list) printf '%s\n' none kvm qemu vmware oracle xen microsoft bochs parallels docker lxc systemd-nspawn; exit 0 ;;
  esac
done

kind=none name=none
if [[ -e /run/systemd/container ]]; then
  kind=container name=$(< /run/systemd/container)
elif [[ -e /.dockerenv ]]; then
  kind=container name=docker
elif [[ -r /proc/1/environ ]] && c=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^container=//p') && [[ -n $c ]]; then
  kind=container name=$c
else
  v=
  [[ -r /sys/class/dmi/id/sys_vendor ]] && v=$(< /sys/class/dmi/id/sys_vendor)
  [[ -r /sys/class/dmi/id/product_name ]] && v+=" $(< /sys/class/dmi/id/product_name)"
  case $v in
    *QEMU*|*KVM*) kind=vm name=kvm ;;
    *VMware*) kind=vm name=vmware ;;
    *innotek*|*VirtualBox*) kind=vm name=oracle ;;
    *Xen*) kind=vm name=xen ;;
    *Microsoft*Virtual*) kind=vm name=microsoft ;;
    *Bochs*) kind=vm name=bochs ;;
    *Parallels*) kind=vm name=parallels ;;
    *) grep -qw hypervisor /proc/cpuinfo 2>/dev/null && { kind=vm name=vm-other; } ;;
  esac
fi

if [[ $want != any && $kind != "$want" ]]; then kind=none name=none; fi
(( quiet )) || echo "$name"
[[ $kind != none ]]
