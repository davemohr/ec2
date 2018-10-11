# Import a VM to EC2

# Create OVF from local VMware image
cd /Applications/VMware\ Fusion.app/Contents/Library/VMware\ OVF\ Tool
./ovftool --acceptAllEulas "~/Documents/Virtual Machines.localized/CentOS-7-64-bit.vmwarevm/CentOS-7-64-bit.vmx" \
~/Documents/VMs/OVF/fullcentos7.ovf

# ensure the import-centos7 S3 bucket is empty, then do the import
ec2-import-instance ~/Documents/VMs/OVF/fullcentos7-disk1.vmdk \
--instance-type m3.large  \
--group dmohr \
--format VMDK \
--architecture x86_64 \
--platform Linux \
--bucket import-centos7 \
--owner-akid $AWS_ACCESS_KEY \
--owner-sak $AWS_SECRET_KEY \
--volume-size 64 \
--debug

# SCP the private key file up to the instance
scp -i foo.pem foo.pem training@ip:~

# Login and configure SSH
sshi -i foo.pem training@ip #login with password "training"

# Create the public key
ssh-keygen -y -f foo.pem > foo.pub

# Setup training's SSH dir
mkdir /home/training/.ssh
chmod 700 /home/training/.ssh
mv foo.pem .ssh/
mv foo.pub .ssh/
cat .ssh/foo.pub > .ssh/authorized_keys
chmod 600 .ssh/authorized_keys
chmod 400 .ssh/foo.pem
chmod 400 .ssh/foo.pub 

# Setup root's ssh dir
sudo su 
mkdir /root/.ssh
chmod 700 /root/.ssh
cp -R /home/training/.ssh/* /root/.ssh/
chmod 600 /root/.ssh/authorized_keys
chmod 400 /root/.ssh/admincourse.pem
chmod 400 /root/.ssh/admincourse.pub 
exit #become training user again

# Configure SSH file	
sudo vim /etc/ssh/sshd_config
Port 22
Port 443	
#comment out the three HostKey entries 
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
ClientAliveInterval 30
ClientAliveCountMax 15000
UseDNS no #as the LAST line in the file

# Configure visudo file
sudo su
su -
visudo
training ALL=(ALL)      NOPASSWD:ALL
%wheel  ALL=(ALL)       NOPASSWD: ALL
exit #out of visudo mode, now root
exit #now training user

# Restart the ssh service and test
sudo systemctl restart sshd
exit #disconnect
sshi -i foo.pem training@ip

# Disable the libvirtd service so that virbr0 disappears from ifconfig
sudo systemctl disable libvirtd
sudo systemctl stop libvirtd
sudo init 6

# Login again and run ifconfig to verify it is gone
# Disable IPv6 at the kernel level and create new init kernel file
sudo vim /etc/default/grub and edit this line, adding the ipv6.disable=1 parameter
GRUB_CMDLINE_LINUX="crashkernel=auto rhgb quiet console=ttyS0 ipv6.disable=1"
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo init 6
