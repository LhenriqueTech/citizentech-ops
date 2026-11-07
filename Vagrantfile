# -*- mode: ruby -*-
# VM Ubuntu 22.04 provisionada automaticamente pelos scripts do projeto.
#   vagrant up          -> cria a VM e roda ./provision.sh
#   vagrant provision   -> roda o provisionamento de novo (idempotente)
#   No host: http://localhost:8080  ou  http://192.168.56.10
Vagrant.configure("2") do |config|
  config.vm.box      = "ubuntu/jammy64"
  config.vm.hostname = "citizentech-srv01"
  config.vm.network "private_network", ip: "192.168.56.10"
  config.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true
  config.vm.boot_timeout = 900

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "citizentech-srv01"
    vb.memory = 2048
    vb.cpus   = 2
    # Console serial em arquivo: evita travamento no boot da box Ubuntu e ajuda no diagnóstico
    vb.customize ["modifyvm", :id, "--uart1", "0x3F8", "4"]
    vb.customize ["modifyvm", :id, "--uartmode1", "file", File.join(__dir__, "vm-console.log")]
  end

  config.vm.provision "shell", privileged: true, inline: <<-SHELL
    cd /vagrant && chmod +x provision.sh scripts/*.sh tools/*.sh monitoring/*.sh
    ./provision.sh
  SHELL
end
