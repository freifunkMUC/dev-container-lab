# Packer variables of the ffbs environment, see gateway/packer/gateway.pkr.hcl.
# Packer runs in gateway/packer, so the paths are relative to it.
# envs/ffbs/prepare.sh makes the staging copy ffbs-stage/.

# The upstream roles use ifupdown, so the base is the Debian generic image.
base_image_url      = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
base_image_checksum = "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
ssh_username        = "debian"
ssh_password        = "ffmuc"

pre_playbook     = "ffbs-stage/lab-pre.yml"
playbook         = "ffbs-stage/playbook.yml"
inventory        = "ffbs-stage/inventory"
overlay_playbook = "ffbs-stage/lab-post.yml"

# The inventory keeps ansible_host for the lab address of each host.
host_var = "ansible_ssh_host"

# with_prod: tasks for hosts outside of the lab.
ansible_extra_arguments = ["--skip-tags", "with_prod"]
ansible_env_vars        = ["ANSIBLE_CONFIG=ffbs-stage/ansible.cfg"]

# The python-venv role copies with rsync.
use_proxy = false
