packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
    ansible = {
      version = "~> 1"
      source = "github.com/hashicorp/ansible"
    }
  }
}

# The defaults build the ffmuc environment. Another environment sets the
# variables in its own file and build.sh passes it with -var-file, see
# envs/*/gateway.pkrvars.hcl and docs/environments.md.

variable "hostname" {
  type = string
}

# Set to true on a machine without a display (for example the CI rig).
variable "headless" {
  type    = bool
  default = false
}

variable "base_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
}

variable "base_image_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"
}

# The login cloud-init gives the default user (cloud-init/user-data).
variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "ssh_password" {
  type    = string
  default = "ffmuc"
}

variable "cd_files" {
  type    = list(string)
  default = ["./cloud-init/*"]
}

variable "memory" {
  type    = string
  default = "1024"
}

# Runs first. For lab preparation that the main playbook needs.
variable "pre_playbook" {
  type    = string
  default = "noop.yml"
}

# The main playbook: the provisioning of the environment.
variable "playbook" {
  type    = string
  default = "ffbs-ansible/playbook.yml"
}

variable "inventory" {
  type    = string
  default = "ffbs-ansible/ffmuc-inventory"
}

# Runs last. For lab changes on top of the main playbook.
variable "overlay_playbook" {
  type    = string
  default = "multipop/overlay.yml"
}

# Added to the arguments of all three playbooks.
variable "ansible_extra_arguments" {
  type    = list(string)
  default = ["--extra-vars", "@multipop/vars.yml"]
}

# The variable that gets the address Ansible connects to. With
# "ansible_ssh_host", the inventory keeps ansible_host for the lab address of
# the host, which some playbooks put into configuration files.
variable "host_var" {
  type    = string
  default = "ansible_host"
}

variable "ansible_env_vars" {
  type    = list(string)
  default = []
}

# false: Ansible connects to the VM directly and not through the Packer SSH
# proxy. Needed for the synchronize (rsync) module. null keeps the default.
variable "use_proxy" {
  type    = bool
  default = null
}

source "qemu" "parker" {
  iso_url           = var.base_image_url
  iso_checksum      = var.base_image_checksum
  disk_image        = true

  output_directory  = "output-${var.hostname}"
  vm_name           = "${var.hostname}.qcow2"
  format            = "qcow2"

  ssh_username      = var.ssh_username
  ssh_password      = var.ssh_password
  ssh_timeout       = "5m"
  shutdown_command  = "echo '${var.ssh_password}' | sudo -S shutdown -P now"

  cd_files         = var.cd_files
  cd_label         = "cidata"

  memory            = var.memory
  disk_size         = "8G"
  accelerator       = "kvm"

  net_device        = "e1000"  # So that netplan doesn't match on it
  disk_interface    = "virtio"
  use_default_display = !var.headless
  headless          = var.headless
}

build {
  sources = ["source.qemu.parker"]
  provisioner "ansible" {
    playbook_file    = var.pre_playbook
    inventory_file   = var.inventory
    ansible_env_vars = var.ansible_env_vars
    use_proxy        = var.use_proxy
    extra_arguments  = concat([
      # Hacky, but needed so we can reference the inventory from the Ansible roles
      "--limit", "${var.hostname}",
      "--extra-vars", "${var.host_var}=${build.Host} ansible_port=${build.Port} ansible_user=${build.User} ansible_ssh_pass=${build.Password}",
    ], var.ansible_extra_arguments)
  }
  provisioner "ansible" {
    playbook_file    = var.playbook
    inventory_file   = var.inventory
    ansible_env_vars = var.ansible_env_vars
    use_proxy        = var.use_proxy
    extra_arguments  = concat([
      # Hacky, but needed so we can reference the inventory from the Ansible roles
      "--limit", "${var.hostname}",
      "--extra-vars", "${var.host_var}=${build.Host} ansible_port=${build.Port} ansible_user=${build.User} ansible_ssh_pass=${build.Password}",
    ], var.ansible_extra_arguments)
  }
  provisioner "ansible" {
    playbook_file    = var.overlay_playbook
    inventory_file   = var.inventory
    ansible_env_vars = var.ansible_env_vars
    use_proxy        = var.use_proxy
    extra_arguments  = concat([
      # Hacky, but needed so we can reference the inventory from the Ansible roles
      "--limit", "${var.hostname}",
      "--extra-vars", "${var.host_var}=${build.Host} ansible_port=${build.Port} ansible_user=${build.User} ansible_ssh_pass=${build.Password}",
    ], var.ansible_extra_arguments)
  }
}
