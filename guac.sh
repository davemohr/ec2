# Install some libraries
sudo yum install -y \
tigervnc-server \
uuid \
libvncserver \
xorg-x11-server-Xvfb \
libpng12 \
xorg-x11-fonts-Type1 \
libXfont \
cairo-devel \
libjpeg-turbo-devel \
libpng-devel \
uuid-devel \
maven

# Configure VNC
su - training
# password: training
vncpasswd
# password: training
# enter view only password? no
vim ~/.vnc/xstartup
    #!/bin/sh
    unset SESSION_MANAGER
    exec /etc/X11/xinit/xinitrc
    [ -x /etc/vnc/xstartup ] && exec /etc/vnc/xstartup
    [ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
chmod +x ~/.vnc/xstartup
sudo cp /usr/lib/systemd/system/vncserver@.service /etc/systemd/system/vncserver@.service
sudo vim /etc/systemd/system/vncserver@.service
# line 39: User=training
# line 40 (new line - this is the actual desktop fix I think!): 
PAMName=login
# line 44: PIDFile=/home/training/.vnc/%H%i.pid
sudo systemctl daemon-reload
sudo systemctl enable vncserver@:1.service
# where 1 is the display (which will run vnc on 5901)
sudo su
gconftool-2 --set --type=bool /desktop/gnome/remote_access/enabled true
exit
sudo systemctl start vncserver@:1.service

# Launch Safari browser
# Type this in the URL field: vnc://192.169.1.9
# In the Screen Sharing app:
52.53.184.87:5901 (where this is the public IP)
password: training
# You should see the gnome desktop (minus any menu bar)

# Download and install Guac
mkdir /home/training/tmp
cd /home/training/tmp
wget https://s3.amazonaws.com/.../guac/guacamole-client-0.9.7-2.noarch.rpm
wget https://s3.amazonaws.com/.../guac/guacd-0.9.7-1.x86_64.rpm
wget https://s3.amazonaws.com/.../guac/tomcat7-7.0.63-1.noarch.rpm
sudo rpm -i tomcat7-7.0.63-1.noarch.rpm
sudo rpm -i guacd-0.9.7-1.x86_64.rpm
# Note: ignore the "/var/tmp/rpm-tmp.MlfRyS: line 3: fg: no job control" response
sudo rpm -i guacamole-client-0.9.7-2.noarch.rpm
cd /etc/guacamole
sudo vim user-mapping.xml
line 3: change username and password
line 7: change port from 5990 to 5901
line 8: change password
move the color depth and encodings lines into the commented out area
sudo vim guacamole.properties

  #comment out this line
  #noauth-config: /etc/guacamole/noauth-config.xml

  #Add these 3 new lines
  auth-provider:          net.sourceforge.guacamole.net.basic.BasicFileAuthenticationProvider
  basic-user-mapping:     /etc/guacamole/user-mapping.xml
  enable-http-auth:       true

# Set services to start at boot and start them now too
sudo systemctl enable guacd
sudo systemctl enable tomcat7
sudo service guacd start
sudo service tomcat7 start

# Test in a browser
http://52.53.184.87:8080/guacamole
login as training/training

# Screen Resolution
# These steps work in a live environment
# in a vnc session terminal
xrandr
# displays all the options
xrandr -s 1920x1200

# Get copy/paste working
# Ctrl-Alt-Shift pulls up the Guacamole clipboard (use the same action to close it)

# Install XRDP
# Not really needed, but these steps work on centos 7
yum -y install xrdp
sudo systemctl restart vncserver@:1.service
sudo systemctl start xrdp
sudo systemctl enable xrdp


