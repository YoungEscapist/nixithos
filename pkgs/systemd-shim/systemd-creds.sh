#!@shell@
# systemd-creds - read the credentials passed to a service (LoadCredential=).
# Encrypted credentials are not supported: there is no TPM or host key
# handling here.

PATH=@path@:$PATH
RUNTIME=@runtime@

args=()
while (( $# )); do
  case $1 in
    --system|--no-pager|--no-legend|--newline=*|--transcode=*|--json=*) ;;
    -*) ;;
    *) args+=("$1") ;;
  esac
  shift
done

dir=${CREDENTIALS_DIRECTORY-}
case ${args[0]-list} in
  list)
    [[ -n $dir && -d $dir ]] || exit 0
    ls -1 "$dir" ;;
  cat)
    [[ -n $dir ]] || { echo "systemd-creds: no credentials passed (\$CREDENTIALS_DIRECTORY is not set)" >&2; exit 1; }
    rc=0
    for name in "${args[@]:1}"; do
      cat "$dir/$name" || rc=1
    done
    exit $rc ;;
  has-tpm2|has-host-key) exit 1 ;;
  *)
    echo "systemd-creds: '${args[0]}' is not supported on this system" >&2
    exit 1 ;;
esac
