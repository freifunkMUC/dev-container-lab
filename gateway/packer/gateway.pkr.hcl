packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "hostname" {
  type = string
}

source "qemu" "parker" {
  iso_url           = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  iso_checksum      = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
  disk_image        = true

  output_directory  = "output-${var.hostname}"
  vm_name           = "${var.hostname}.qcow2"
  format            = "qcow2"

  ssh_username      = "ubuntu"
  ssh_password      = "ffmuc"
  ssh_timeout       = "5m"
  shutdown_command  = "echo 'ffmuc' | sudo -S shutdown -P now"

  cd_files         = ["./cloud-init/*"]
  cd_label         = "cidata"

  memory            = "1024"
  disk_size         = "8G"
  accelerator       = "kvm"

  net_device        = "e1000"  # So that netplan doesn't match on it
  disk_interface    = "virtio"
}

build {
  sources = ["source.qemu.parker"]
  provisioner "ansible" {
    playbook_file = "ffbs-ansible/playbook.yml"
    inventory_file = "ffbs-ansible/ffmuc-inventory"
    extra_arguments = [
      "--vault-password-file=ffbs-ansible/.vault",
      # Hacky, but needed so we can reference the inventory from the Ansible roles
      "--limit", "${var.hostname}",
      "--extra-vars", "ansible_host=${build.Host} ansible_port=${build.Port} ansible_user=${build.User} ansible_ssh_pass=${build.Password}"
    ]
  }
}
