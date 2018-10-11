# Setup the EC2-API Tools on your Mac
#Download and install (extract) the ec2-api-tools from Amazon (e.g. from http://aws.amazon.com/developertools/351) 
#Add these environment variables to ~/.bash_profile on your mac:
EC2_HOME=/Users/dmohr/Documents/aws/ec2-api-tools-1.7.1.1
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/Users/dmohr/Documents/aws/ec2-api-tools-1.7.1.1/bin
EC2_URL=https://ec2.us-west-1.amazonaws.com
AWS_ACCESS_KEY=...
AWS_SECRET_KEY=...


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

# Observe the status of the import. The import as indicated in the Terminal completes in just a few minutes. 
# However, processing of the import on the EC2 side takes a while (maybe 30 minutes or so). 
# Run ec2-describe-conversion-tasks to see the progress. When the result of the command shows progress “100%” 
# you can continue to the next step.
ec2-describe-conversion-tasks

# If the import fails after uploading part but not all of the image, try using the ec2-resume-import command. Example:
# ec2-resume-import ~/Documents/VMs/OVF/admin532-disk1.vmdk -t import-i-ffz0wnmj -o $AWS_ACCESS_KEY -w $AWS_SECRET_KEY
# Note: you can find the import-i-... id in the initial terminal output from the ec2-import-instance command you issued earlier. 

# If the import fails and you can’t delete the instance that shows up in the AWS Management Console, 
# run this command ec2-cancel-conversion-task task_id (where task_id is the task_id you find by running
# the command ec2-describe-conversion-tasks)

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

# Example export instance to local VMware
aws ec2 create-instance-export-task \
--instance-id i-blahblah \
--target-environment vmware \
--export-to-s3-task DiskImageFormat=VMDK,S3Bucket=somebucket,S3Prefix=gateway-

{
    "ExportTask": {
        "State": "active", 
        "InstanceExportDetails": {
            "InstanceId": "i-blahblah", 
            "TargetEnvironment": "vmware"
        }, 
        "ExportToS3Task": {
            "S3Bucket": "somebucket", 
            "S3Key": "gatewayexport-i-blahblah.ova", 
            "DiskImageFormat": "vmdk", 
            "ContainerFormat": "ova"
        }, 
        "ExportTaskId": "export-i-blahblah"
    }
}

# Convert VMDK (from EC2) to VMWare Fusion
#From VMWare Fusion, select File -> New…
#Choose Create a custom virtual machine, and click Continue
#Select Linux -> Red Hat Enterprise Linux 6 64-bit, and click Continue
#Select, “Use an existing virtual disk” and click Choose virtual disk…
#Choose the vmdk downloaded from EC2, and click Continue and Finish
#Save As: <enter the new VM name>

