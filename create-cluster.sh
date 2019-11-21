#!/bin/bash
#
echo
echo "Started running create-cluster.sh at $(date '+%Y-%m-%d %T')"

nocheck="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error"
source config/CM_API_functions.sh

set_access() {
	#get or renew IAM role creds
	iamRole=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
	sed -i 's/replace-cmhost-iam-role/'"$iamRole"'/g' /home/training/config/update-s3-creds.sh
	cd /home/training/config
	./update-s3-creds.sh
	sleep 3
}

verify_host() {
	cmhostIp=$(cat /etc/hosts | grep -i cmhost | awk '{print $1}')
	if [[ "$cmhostIp" == "" ]]; then
		echo "A cmhost entry was not found in /etc/hosts."
		echo "Fix this by running the config_hosts_files.sh script from your VM before running this script. Exiting."
		exit 0
	fi
}

#Called from one of three locations in check_if_existing_clusters
cleanup_hosts() {
	echo
	echo "Deleting any existing CDH node entries from /etc/hosts on cmhost."
	sudo sed -i '/gateway/d' /etc/hosts
	sudo sed -i '/worker/d' /etc/hosts
	sudo sed -i '/master/d' /etc/hosts
	sudo sed -i '/cdsw2/d' /etc/hosts
}

#Called from one of three locations in check_if_existing_clusters
cleanup_and_log() {
	#remove any logs from old cluster
	rm -f cluster.log
	rm -f clustererr.out
	sudo rm -rf /home/training/config/working
 	sudo rm -rf /home/training/working

	#capture stout and sterr to log files
	exec > >(tee -ia cluster.log)
	echo "Started logging create-cluster.sh at $(date '+%Y-%m-%d %T')"
	exec 2> >(tee -ia clustererr.out)

	#drop tables - this cleans out the oozie db among other things, drops all CDH DBs but not the cmserver DB
	echo
	echo "Cleaning up the CDH databases for a new cluster."
	mkdir -p /home/training/config
	cd /home/training/config
	./drop-tables.sh
	cd /home/training
}


check_if_existing_clusters(){
	
	clusters=$(curl -s -X GET -u "admin:admin" -i http://localhost:7180/api/v8/clusters/)
	if [[ $? -ne 0 ]]; then
		cleanup_hosts
		cleanup_and_log
		echo "No existing clusters found."
	else
		clusterN=$(echo $clusters | cut -d '"' -f6)
		if [[ "$clusterN" == "" ]]; then
			cleanup_hosts
			cleanup_and_log
			echo 
			echo "No existing clusters were found."
		else	
			echo
			echo "Found existing cluster named "$clusterN". Do you want to delete it? [Y/N]"
			echo ">>"

			validResp=0
			while  [  $validResp -eq 0 ];
			do
				read answer
				if [[ "$answer" == "Y" || "$answer" == "y" ]]; then
					cleanup_hosts
					cleanup_and_log
					echo 
					echo "OK. This script will first stop the existing cluster, then delete it."
					echo "Stopping cluster now. This typically takes 1 to 3 minutes, please be patient."
					callCmApi http://localhost:7180/api/v12/clusters/$clusterN/commands/stop POST
					#stopcmd=$(curl --silent -X POST -u admin:admin http://localhost:7180/api/v12/clusters/$clusterN/commands/stop) 2>>/dev/null

					status=$(curl --silent -X GET -u admin:admin http://localhost:7180/api/v12/clusters/$clusterN | grep entityStatus | cut -d '"' -f4) 2>>/dev/null
					
					while [[ "$status" == "STOPPING" || "$status" == "BAD_HEALTH" || "$status" == "GOOD_HEALTH" ]];
					do
						count=0
						while [ $count -lt 10 ];
						  do
						    count=$(( $count + 1 ))
						    printf "."
				    		sleep 1
						  done
						  status=$(curl --silent -X GET -u admin:admin http://localhost:7180/api/v12/clusters/$clusterN | grep entityStatus | cut -d '"' -f4) 2>>/dev/null
						  if [[ "$status" == "STOPPED" ]]; then
						  	counter=0
						  	while [ $counter -lt 200 ]
						  		do
						  			counter=$(( $counter + 1 ))
						  			printf "."
						  			sleep 1
						  		done
							printf "\n"
						  fi
					done
					
					

					echo
					echo "Deleting the cluster from Cloudera Manager now..."
					echo
					echo "NOTE: this does not actually terminate the instances on which the cluster ran."
					callCmApi http://localhost:7180/api/v12/clusters/$clusterN DELETE 
					checkPending
					
					validResp=1

					#ensure DB entries for removed hosts are gone
					cmhostConn="-s -N -P 3306 -uroot -ptraining"
					mysql $cmhostConn -e "DELETE FROM cmserver.HOSTS WHERE NAME LIKE '%gateway%';"
					mysql $cmhostConn -e "DELETE FROM cmserver.HOSTS WHERE NAME LIKE '%master%';"
					mysql $cmhostConn -e "DELETE FROM cmserver.HOSTS WHERE NAME LIKE '%worker%';"
					
					#mysql $cmhostConn -e "DELETE FROM cmserver.HOSTS WHERE NAME LIKE '%cdsw%';"
					
					#count=$(mysql $cmhostConn -e "SELECT NAME from cmserver.HOSTS;" | wc -l)

					echo
					echo "Retagging the no longer needed instances now..."
					#retag the orphaned instances
					aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep m1instanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep m2instanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep w1instanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep w2instanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep w3instanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep ginstanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					#aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep cdswginstanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json
					#aws ec2 create-tags --resources $(cat /home/training/.ngee-instances | grep cdsw2instanceId | awk '{print $2}') --tags Key=Name,Value=orphanedInstance$nameTag-$name --output json

					echo
					echo "Stopping the no longer needed instances now..."
					#stop the orphaned instances
					reg=$(sudo curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep '\"region\"' | cut -d\" -f4)
					aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep m1instanceId | awk '{print $2}') --output json 
					aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep m2instanceId | awk '{print $2}') --output json 
					aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep w1instanceId | awk '{print $2}') --output json 
					aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep w2instanceId | awk '{print $2}') --output json 
					aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep w3instanceId | awk '{print $2}') --output json 
					aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep ginstanceId | awk '{print $2}') --output json 
					#aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep cdswginstanceId | awk '{print $2}') --output json 
					#aws ec2 stop-instances --region $reg  --instance-ids $(cat /home/training/.ngee-instances | grep cdsw2instanceId | awk '{print $2}') --output json 

				elif [[ "$answer" == "N" || "$answer" == "n" ]]; then
					echo "OK, preserving your original cluster. This script will now exit."
					exit 1
				else
					echo "Please reply with Y or N."
				fi
			done
		fi
	fi

	existingHosts=$(curl -s -X GET -u "admin:admin" -i http://localhost:7180/api/v8/hosts/ | grep 'master\|worker\|gateway' |wc -l)
	if [[ "$existingHosts" != "0" ]]; then
		echo
		echo "Found existing hosts other than cmhost. Removing them from CM now."

		nonCmHosts=$(curl -s -X GET -u "admin:admin" -i http://localhost:7180/api/v8/hosts/ | grep -B 3 'master\|worker\|gateway' | grep hostId | cut -d '"' -f4)
		numHosts=$(echo $nonCmHosts | wc -w)
		x=1
		while [ $x -le $numHosts ]
		do	
		  hostId=$(echo $nonCmHosts | cut -d ' ' -f$x)
		  #echo "hostId to be deleted="$hostId
		  callCmApi http://localhost:7180/api/v12/hosts/$hostId DELETE
		  #checkPending
		  x=$(( $x + 1 ))
		done
		echo "Removed $numHosts hosts from Cloudera Manager."	
	fi
}

get_metadata() {
	echo "Collecting metadata."
	cmAmiInUse=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
	mac=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
	subnetId=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/subnet-id)
	isuse1=$(curl -s http://169.254.169.254/latest/meta-data/hostname | grep  compute )
	if [[ "$isuse1" == "" ]]; then
		region="us-east-1"
	else
		region=$(curl -s http://169.254.169.254/latest/meta-data/hostname | cut -d . -f 2)
	fi
	instanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
	nameTag=$(aws ec2 describe-tags --region $region --output json --filters "Name=resource-id,Values=$instanceId" | grep -B1 '"Key": "Name"' | grep '"Value"' | cut -d '"' -f4 | cut -d '-' -f -3)
}

get_cluster_name() {
  validResponse=0
  while [ $validResponse -eq 0 ] 
  do 
    echo ""
    echo "Please enter a name for your cluster (suggestion: use your last name). "
    echo "Do not use spaces or special characters.  Do not exceed 20 characters."
    echo
    echo "If you already created a cluster before with this cmhost,"
    echo "do not use the same cluster name twice."
	echo ">> "
    read name

    if [[ "$name" != "" ]] && [[ "$name" =~ ^[a-zA-Z0-9]+$ ]]; then
      name=$(echo $name | awk '{print $1}' | cut -c1-20)
      validResponse=1
    else 
      echo ""
      echo "Invalid response. Please re-enter a valid name (ASCII letters only)." 
      echo ""
    fi
  done  

  enableTLS="N"
  if [[ "$name" == "dev" || "$name" == "cluster1" || "$name" == "cluster2" ]]; then
  	enableTLS="Y"
  fi
} 

get_course_name() {
	validResponse=0
	while [ $validResponse -eq 0 ] 
	do 
	    echo ""
	    echo "Please enter the number of the course you have signed up for."
	    echo ""
	    echo " 1 BDA (Big Data Architecture Workshop)"
	    echo " 2 DA (Data Analyst Training)"
	    echo " 3 DS (Data Science Training)" 
	    echo " 4 DevSH (Developer for Spark and Hadoop)" 
	    echo " 5 HBase (HBase Training)" 
	    echo " 6 JEP (Just Enough Python)" 
	    echo " 7 JES (Just Enough Scala)"
	    echo " 8 JMR"
	    echo " 9 Kafka"
	    echo "10 Kudu"
	    echo "11 MLlib (Introduction to Machine Learning)"
	    echo "12 Search (Search Training)"
	    echo "13 Custom"
	    echo "14 None"
	    echo ">>"
	    read course
	    if [[ $course -ge 1 && $course -le 14 ]]; then
	      validResponse=1
	    else 
	      echo ""
	      echo "Invalid response. Please enter the number for the course." 
	      echo ""
	    fi
	done  
	
	#PROCESS RESULTS OF FIRST QUESTION
	if [[ "$course" == "1" ]]; then
		course="BDA"
	elif [[ "$course" == "2" ]]; then
		course="DA"
	elif [[ "$course" == "3" ]]; then
		course="DS"
	elif [[ "$course" == "4" ]]; then
		course="DevSH"
	elif [[ "$course" == "5" ]]; then
		course="HBase"
	elif [[ "$course" == "6" ]]; then
		course="JEP"
	elif [[ "$course" == "7" ]]; then
		course="JES"
	elif [[ "$course" == "8" ]]; then
		course="JMR"
	elif [[ "$course" == "9" ]]; then
		course="Kafka"
	elif [[ "$course" == "10" ]]; then
		course="Kudu"
	elif [[ "$course" == "11" ]]; then
		course="MLlib"
	elif [[ "$course" == "12" ]]; then
		course="Search"
	elif [[ "$course" == "13" ]]; then
			
			course="Custom"

			#START FIRST QUESTION
			custResponse=0
			while [ $custResponse -eq 0 ] 
			do 
			  echo ""
			  echo "Custom courses require a code."
			  echo ""
			  echo "Please enter the code provided by your instructor."
			  echo "The code should include three numbers separated by periods."
			  echo ""
			  echo ">>"
			  read customID
			  #check for a specific A.B.C sequence where where A is a number between 1 to 3 digits, B is 1 to 3 digits, and C is 1 to 4 digits
			  if [[ $customID =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4}$ ]]; then
			
			custResponse=1
			else
			  	echo ""
			  	echo ">> Please enter a well-formed custom code."

			fi
			done
			#END FIRST QUESTION
			echo
			echo "Build Number = "$customID
			#echo "customCourseType="$customCourseType

	#LAST get_course_name option
	elif [[ "$course" == "14" ]]; then
		course="None"
	fi
}

rds_lookups1(){
	cm_version=$(curl -s -u admin:admin -X GET "http://localhost:7180/api/v9/cm/version"  | grep -i version | cut -d '"' -f4 )
	#TO DO: test if cm_version call was successful and also check health status of CM

	cdh_version=$(sudo ls -d /opt/cloudera/parcels/* | grep CDH- | cut -d '-' -f2)
	rdsConnection="-s -N -h ngeedb.cuzgndguf1op.us-west-1.rds.amazonaws.com -P 3306 -urouser -pClouderaCluster"

	echo "Course = "$course

	echo ""
	echo "Looking up course data."
	if [[ "$course" != "Custom" ]]; then
		isCustom="no"
		#get build code
		###################################################################################################################
		lookup1=$(mysql $rdsConnection -e "SELECT build, MAX(releaseDate) FROM NGEEDB.course_releases WHERE courseAbbr=\"$course\" AND cdh=\"$cdh_version\";") 
		###################################################################################################################
		build=$(echo $lookup1 | awk '{print $1}')	
		releaseDate=$(echo $lookup1 | awk '{print $2}')
		courseRelease=$(echo $course"-"$releaseDate)

		#error checking
		if [[ "$build" == "" ||  "$releaseDate" == "" ||  "$courseRelease" == "" || "$build" == "NULL" ||  "$releaseDate" == "NULL" ||  "$courseRelease" == "NULL"  ]]; then
			echo "ERROR: course information not found. This may indicated a mismatch "
			echo "between the CDH version supported by this cmhost which is "$cdh_version
			echo "and the version of CDH that the latest "$course "should run on."
			echo "Please verify with your instructor that you have the correct cmhost. Exiting."
			exit 1
		fi

		#parse the build code into its three components
		amiSetId=$(echo $build | cut -d '.' -f1)
		ngeeScriptsId=$(echo $build | cut -d '.' -f2)
		courseScriptsId=$(echo $build | cut -d '.' -f3)

	else
		isCustom="yes"
		#Custom Course
		build=$customID

		#parse the build code into its three components
		amiSetId=$(echo $build | cut -d '.' -f1)
		ngeeScriptsId=$(echo $build | cut -d '.' -f2)
		courseScriptsId=$(echo $build | cut -d '.' -f3)

		#For this Custom Course, get course type and releaseDate so that we know what IAM role to assign the gateway node 
		#and what the training materials file name will be
		
		###################################################################################################################
		lookup1=$(mysql $rdsConnection -e "SELECT courseAbbr, releaseDate, materialsFileName FROM NGEEDB.course_scripts WHERE courseScriptsId=\"$courseScriptsId\";") 
		###################################################################################################################
		
		#releaseDate=$(echo $lookup1 | awk '{print $2}' | sed 's/-//g' | cut -c1-6)
		releaseDate=$(echo $lookup1 | awk '{print $2}')
		materialsFileName=$(echo $lookup1 | awk '{print $3}')
		
		#Change the course from Custom to whatever course type this actually is as indicated by the course_scripts table row referenced in the build number
		course=$(echo $lookup1 | awk '{print $1}') #typically the courseAbbr, but it could be a series of dashed numbers
		courseRelease=$(echo $course"-"$releaseDate)

		#This logic handles a custom course that uses materials from multiple courses
		checkForMultiCustom=$(echo $course | grep -o "-" | wc -l ) #notices if courseAbbr is not an actual courseAbbr
			
		if [[ "$checkForMultiCustom" != "0" && "$checkForMultiCustom" != "" ]]; then
			#multi custom course
			echo
			echo "You entered a build number that indicates that this is a custom course."
			numCourses=$(( $checkForMultiCustom + 1 ))
			counter="1"
			rm -f /home/training/.ngee-courses.txt
			touch /home/training/.ngee-courses.txt
			while [ $counter -le $numCourses ]
			do
				#find the releaseId
				courseFound=$(echo $course | cut -d "-" -f$counter )
				
				#lookup the course details
				###################################################################################################################
				lookupCourse=$(mysql $rdsConnection -e "SELECT courseAbbr, releaseDate, build FROM NGEEDB.course_releases WHERE releaseId=\"$courseFound\";") 
				###################################################################################################################
				courseAbbrev=$(echo $lookupCourse | awk '{print $1}') #now we have an actual courseAbbr
				echo "courseAbbr"$counter" : "$courseAbbrev >> /home/training/.ngee-courses.txt
				currentBuild=$(echo $lookupCourse | awk '{print $3}')
				currentCourseScriptsId=$(echo $currentBuild | cut -d '.' -f3)

				###################################################################################################################
				lookupZip=$(mysql $rdsConnection -e "SELECT materialsFileName, runSetup FROM NGEEDB.course_scripts WHERE courseScriptsId=\"$currentCourseScriptsId\";") 
				###################################################################################################################
				materialsFileNameNum=$(echo $lookupZip | awk '{print $1}') #we now have the zip file name
				echo "materialsFileName"$counter" : "$materialsFileNameNum >> /home/training/.ngee-courses.txt
				runSetupNum=$(echo $lookupZip | awk '{print $2}') #we now know if we should execute the embedded setup.sh
				echo "runSetup"$counter" : "$runSetupNum >> /home/training/.ngee-courses.txt
				counter=$(( $counter + 1 ))	
			done
		else
			#single custom course
			#typically used during development
			checkForMultiCustom=""
		fi
	fi
}

get_top_level_domain() {

	if [[ $course != "CDSW" ]]; then
		# Top Level Domain is only needed in CDSW
		topDomain='example.com'
		return 1
	fi
	
	validResponse=0
	while [ $validResponse -eq 0 ] 
	do 
	  echo ""
	  echo "Please enter a top-level domain name. "
	  echo "Do not use spaces or special characters."
	  echo
	  echo ">> "
	  read topDomain

	  regex="^[a-z]+(\.[a-z]+)?$"
	  if [[ "$topDomain" != "" ]] && [[ "$topDomain" =~ $regex ]]; then
	    validResponse=1
	  else 
	    echo ""
	    echo "Invalid response. Please re-enter a valid top level domain name." 
	    echo "NGEE-CDSW expects a top level domain to have a range of characters separated by a dot"
	    echo ""
	  fi
	done  

}

cdsw_update_scripts() {

	if [[ "$name" == "dev" || "$name" == "cluster1" || "$name" == "cluster2" ]]; then
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_cdsw2_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_gateway_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_cdswgateway_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_master-1_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_master-2_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_worker-1_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_worker-2_host.sh 
		sed -i 's/replace-cluster-name/'"$name."'/g' /home/training/config/cdsw/update_worker-3_host.sh
	else
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_cdsw2_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_gateway_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_cdswgateway_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_master-1_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_master-2_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_worker-1_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_worker-2_host.sh 
		sed -i 's/replace-cluster-name//g' /home/training/config/cdsw/update_worker-3_host.sh	 
	fi

	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_cdsw2_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_gateway_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_cdswgateway_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_master-1_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_master-2_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_worker-1_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_worker-2_host.sh 
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/cdsw/update_worker-3_host.sh


	#ensure that we always have the standard update files in the noncdsw dir
	if [[ ! -f /home/training/config/noncdsw/update_master-1_host.sh ]]; then
		echo "Backing up the standard update scripts."
		mkdir -p /home/training/config/noncdsw
		cp /home/training/config/*_host.sh /home/training/config/noncdsw/
	fi

	#if the update files aren't there, copy the regular ones back where they belong
	if [[ ! -f /home/training/config/update_master-1_host.sh ]]; then
		echo "No update scripts in standard location. Copying the standard ones there now."
		cp /home/training/config/noncdsw/*_host.sh /home/training/config/
	fi

	if [[ "$course" == "CDSW" ]] && [[ ! -f /home/training/config/update_cdsw2_host.sh ]]; then
		echo "The course is CDSW and the CDSW update scripts are not yet in place. Placing them there now."
		#copy in the new scripts
		cp /home/training/config/cdsw/*_host.sh /home/training/config/
	fi
	if [[ "$course" != "CDSW" ]] && [[ -f /home/training/config/update_cdsw2_host.sh ]] && [[ "$checkForMultiCustom" == "" ]]; then
		echo "The course is not CDSW and it is not a multi-course custom course, "
		echo "but this cmhost was previously used to create a CDSW cluster. Swapping "
		echo "the standard update scripts in."
		#copy in the new scripts
		cp /home/training/config/cdsw/*_host.sh /home/training/config/
	fi
	#update S3 creds again, in case we now have a different IAM role
	cd ~/config 
	./update-s3-creds.sh
}

rds_lookups2(){

	#error checking for if any of these values are blank
	if [[ "$amiSetId" == "" ||  "$ngeeScriptsId" == "" ||  "$courseScriptsId" == "" ]]; then
		echo 
		echo "ERROR: create-cluster was not able to determine which cluster type to build. "
		echo "Exiting."
		exit 1
	fi

	echo "Looking up account and security group."
	###################################################################################################################
	getacctAndSg=$(mysql $rdsConnection -e "SELECT account, securityGroup, scriptsBucket, coursesBucket FROM NGEEDB.placement WHERE subnetId=\"$subnetId\" AND description='standard';") 
	###################################################################################################################
	#account value will now be iether 'dev' or 'prod'
	account=$(echo $getacctAndSg | awk '{print $1}')
	sgId=$(echo $getacctAndSg | awk '{print $2}')
	scriptsBucket=$(echo $getacctAndSg | awk '{print $3}')
	coursesBucket=$(echo $getacctAndSg | awk '{print $4}')

	#prep for next DB query
	r=$(echo $region | sed 's/-//g' | sed 's/^[ \t]*//;s/[ \t]*$//')
	if [[ "$r" == "euwest1" ]]; then
		#this region has a different db column name
		r="ireland"
	elif [[ "$r" == "apsoutheast1" ]]; then
		#this region has a different db column name
		r="singapore"
	elif [[ "$r" == "apsoutheast2" ]]; then
		#this region has a different db column name
		r="sydney"
	elif [[ "$r" == "apnortheast1" ]]; then
		#this region has a different db column name
		r="tokyo"
	fi
	m1=$(echo $r"master1")
	m2=$(echo $r"master2")
	w1=$(echo $r"worker1")
	w2=$(echo $r"worker2")
	w3=$(echo $r"worker3")
	g=$(echo $r"gateway")
	c=$(echo $r"cmhost")
	
	if [[ "$course" == "CDSW" ]]; then
		cdswg=$(echo $r"cdsw")
		cdsw2=$(echo $r"cdsw2")
	fi

	#get non-standard security group for CDSW
	if [[ "$course" == "CDSW" ]]; then
		#HARDCODED - assumes dev account
		echo "Looking up security group for CDSW."
		###################################################################################################################
		sgId=$(mysql $rdsConnection -e "SELECT securityGroup FROM NGEEDB.placement WHERE account=\"$account\" AND region=\"$region\" AND description='cdsw';") 
		###################################################################################################################
	fi	
	
	
	#error checking
	if [[ "$sgId" == "" ]]; then
		echo "ERROR: create-cluster was not able determine the security group id. Exiting. "
		exit 1
	fi

	#get ami ids 
	echo "Looking up AMI IDs."
	###################################################################################################################
	amis=$(mysql $rdsConnection -e "SELECT $m1, $m2, $w1, $w2, $w3, $g, cm, cdh, $c FROM NGEEDB.ami_set WHERE amiSetId=\"$amiSetId\";")
	###################################################################################################################
	m1ami=$(echo $amis | awk '{print $1}')
	m2ami=$(echo $amis | awk '{print $2}')
	w1ami=$(echo $amis | awk '{print $3}')
	w2ami=$(echo $amis | awk '{print $4}')
	w3ami=$(echo $amis | awk '{print $5}')
	gami=$(echo $amis | awk '{print $6}')

	if [[ "$course" == "CDSW" ]]; then
		echo "Looking up the cdsw AMI IDs."
		###################################################################################################################
		cdswamis=$(mysql $rdsConnection -e "SELECT $cdswg, $cdsw2 FROM NGEEDB.ami_set WHERE amiSetId=\"$amiSetId\";")
		###################################################################################################################
		cdswgami=$(echo $cdswamis | awk '{print $1}')
		cdsw2ami=$(echo $cdswamis | awk '{print $2}')
	fi

	cmvers=$(echo $amis | awk '{print $7}')
	cdhvers=$(echo $amis | awk '{print $8}')

	#check for incompatible build number given this cmhost
	indicatedCmAmi=$(echo $amis | awk '{print $9}')
	compIssue="no"

	if [[ "$indicatedCmAmi" != "$cmAmiInUse" ]]; then
		echo ""
		echo "WARNING: The build number you entered is not supported by this cmhost."
		echo "The cmhost you are running was instantiated from "$cmAmiInUse
		echo "The build number you entered indicates you should use a cmhost instantiated from "$indicatedCmAmi
		###################################################################################################################
		options=$(mysql $rdsConnection -e "SELECT amiSetId FROM NGEEDB.ami_set WHERE $c=\"$cmAmiInUse\";")
		###################################################################################################################
		if [[ "$options" == "" ]]; then
			echo ""
			echo "The cmhost you are running is not known to support any known build numbers. Please consult with your instructor regarding next steps."
			compIssue="yes"
			
			vResponse=0
			while [ $vResponse -eq 0 ] 
			do 
				echo 
				echo ">> Do you want to continue anyway? [Y/N]"
				read answer
				if [[ "$answer" == "Y" || "$answer" == "y" ]]; then
					echo "OK, just know that the first number in your build number will be ignored.... "
					vResponse=1
				elif [[ "$answer" == "N" || "$answer" == "n" ]]; then
					echo "OK, exiting."
					exit 1
				else
					echo "Please reply with Y or N."
				fi
			done
			#exit 1
		else
			echo ""
			echo "The cmhost you are using supports build numbers that start with "
			
			count=$(echo $options | tr -cd ' \t' | wc -c)
			count=$(( $count + 1 )) 
			x=1
			while [ $x -le $count ]
			do	
				num=$(echo $options | awk '{print $x}')
				echo $num
				x=$(( $x + 1 )) 
			done
			
			vResponse=0
			while [ $vResponse -eq 0 ] 
			do 
				echo
				echo ">> Do you want to continue? [Y/N]"
				echo "Note: if you want to specify a different build number choose 'N'."

				read answer
				if [[ "$answer" == "Y" || "$answer" == "y" ]]; then
					echo "OK, just know that the first number in your build number will be ignored.... "
					compIssue="yes"
					vResponse=1
				elif [[ "$answer" == "N" || "$answer" == "n" ]]; then
					echo "OK, exiting. Please consult with your instructor regarding next steps."
					exit 1
				else
					echo "Please reply with Y or N."
				fi
			done
		fi
	fi
	
	incompCmVer="no"
	if [[ "$cmvers" != "$cm_version" ]]; then
		echo
		echo "The database lookup reports that this cluster should use CM "$cmvers", however the CM API reports version "$cm_version" is installed on cmhost."
		incompCmVer="yes"
	fi

	incompCdhVer="no"
	if [[ "$cdhvers" != "$cdh_version" ]]; then
		echo
		echo "The database lookup reports that this cluster should use CDH "$cdhvers", however CDH version "$cdh_version" was found in /opt/cloudera/parcels on the cmhost."
		incompCdhVer="yes"
	fi

	#error checking
	if [[ "$m1ami" == "" ||  "$m2ami" == "" ||  "$w1ami" == ""  ||  "$w2ami" == ""  ||  "$w2ami" == ""  ||  "$gami" == "" ]]; then
		echo
		echo "ERROR: create-cluster was not able discover all AMI IDs. "
		echo 
		echo "master-1 AMI ID:"$m1ami
		echo "master-2 AMI ID:"$m2ami
		echo "worker-1 AMI ID:"$w1ami
		echo "worker-2 AMI ID:"$w2ami
		echo "worker-3 AMI ID:"$w3ami
		echo "gateway AMI ID:"$gami
		echo 
		echo "Exiting."
		exit 1
	fi
	if [[ "$course" == "CDSW" ]]; then
		if [[ "$cdswgami" == "" ||  "$cdsw2ami" == "" ]]; then
			echo
			echo "ERROR: create-cluster was not able discover all AMI IDs. "
			echo 
			echo "cdsw-gateway AMI ID:"$cdswgami
			echo "cdsw2 AMI ID:"$cdsw2ami
			echo 
			echo "Exiting."
			exit 1
		fi

		#test if route53 entries already exist
		r53exist=$(aws route53 list-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --output text | grep $name)
		
		if [[ "$r53exist" != "" ]]; then			
			#count existing records
			numrecs=$(echo $r53exist | grep -o 'RESOURCERECORDSETS' | wc -l)
			echo
			echo "----------------------------------------------------------"
			echo "ALERT:"
			echo $numrecs" existing route53 entries were found for "$name"."
			echo "----------------------------------------------------------"

			#check if existing cluster's web UI is active
		
			echo 
			echo "CAUTION: If the other cluster is running, overwriting the entries "
			echo " will break that cluster (unless the instructor at a later time runs "
			echo "/home/training/config/update-route53.sh from their cmhost in which case,"
			echo "when they do that it will break the cluster you are building now)."
			echo ""
			echo "You cannot have two clusters with the same cluster name running anywhere"
			echo "globally at the same time. However, as long as other clusters with the "
			echo "same name are not actively running at the same time, then they can co-exist "
			echo "(e.g. all in a stopped state except for one active one)."
			echo 
			echo "--------------------------------------------------------------------------------"
			echo ">> Would you like to map the existing route53 records to your new cluster? [Y/N]"
			echo "--------------------------------------------------------------------------------"
			echo
			echo "If you answer no, this script will stop running and no cluster will be created."	
			echo

			validResp=0
			while  [  $validResp -eq 0 ];
			do
				read answer
				if [[ "$answer" == "Y" || "$answer" == "y" ]]; then
					echo 
					echo "OK, later in this script the existing route53 records will be updated to point"
					echo "to your new CDSW cluster."
					validResp=1
				elif [[ "$answer" == "N" || "$answer" == "n" ]]; then
					echo "OK, this script will now exit."
					exit 1
				else
					echo "Please reply with Y or N."
				fi
			done
		fi
	fi

	#get the ngee scripts
	echo
	echo "Looking up CM template and CM API script names."
	###################################################################################################################
	ngeescripts=$(mysql $rdsConnection -e "SELECT bootstrap, cmapi FROM NGEEDB.ngee_scripts WHERE ngeeScriptsId=\"$ngeeScriptsId\";")
	###################################################################################################################
	
	#get CM template 
	cmTemplate=$(echo $ngeescripts | awk '{print $1}')
	if [[ "$cmTemplate" == "" ]]; then
		echo "ERROR: No reference to the CM template found in ngee_scripts table data returned. Exiting."
		exit 1
	else
		echo "Downloading CM template."
		aws s3 cp --only-show-errors s3://$scriptsBucket/$cmTemplate /home/training/ 
		sudo chown training:training /home/training/$cmTemplate
	fi
	
	#get CM API script
	cmapifile=$(echo $ngeescripts | awk '{print $2}')
	if [[ "$cmapifile" == "" ]]; then
		echo "ERROR: No reference to CM API script found in ngee_scripts table. Exiting."
		exit 1
	else
		echo "Downloading CM API script."
		aws s3 cp --only-show-errors s3://$scriptsBucket/$cmapifile /home/training/config/ 
		sudo chown training:training /home/training/config/$cmapifile
		chmod +x /home/training/config/$cmapifile
	fi

	if [[ "$course" != "14" && "$checkForMultiCustom" == "" ]]; then
		#As long as course is not "None", and there are not multiple courseAbbrs, then get the course-specific scripts
		###################################################################################################################
		coursescripts=$(mysql $rdsConnection -e "SELECT materialsFileName, runSetup FROM NGEEDB.course_scripts WHERE courseScriptsId=\"$courseScriptsId\";")
		###################################################################################################################
		materialsFileName=$(echo $coursescripts | awk '{print $1}')
		runSetup=$(echo $coursescripts | awk '{print $2}')

		if [[ "$materialsFileName" == "" ]]; then
			echo "ERROR: No reference to the training_materials filename was found in the course_scripts table. Exiting."
			exit 1
		fi
		if [[ "$runSetup" == "" ]]; then
			echo "ERROR: No indication as to whether to run the course-specific setup file contained in " $materialsFileName " was found in course_scripts table. Exiting."
			exit 1
		fi
	fi
}

display_settings() {
	echo
	echo "=================================================" | tee /home/training/.ngee-build
	echo "Summary of settings"								 | tee -a /home/training/.ngee-build
	echo "-------------------------------------------------" | tee -a /home/training/.ngee-build
	echo ""	| tee -a /home/training/.ngee-build
	echo "Account: "$account | tee -a /home/training/.ngee-build
	echo "Region: "$region | tee -a /home/training/.ngee-build
	echo "Subnet ID: "$subnetId | tee -a /home/training/.ngee-build
	echo "Security Group ID: "$sgId | tee -a /home/training/.ngee-build
	echo "cmhost AMI ID: "$cmAmiInUse | tee -a /home/training/.ngee-build
	echo "cmhost role: "$iamRole | tee -a /home/training/.ngee-build 
	echo "cmhost incompatible with build number?: "$compIssue | tee -a /home/training/.ngee-build
	echo "Master-1 AMI ID: "$m1ami | tee -a /home/training/.ngee-build
	echo "Master-2 AMI ID: "$m2ami | tee -a /home/training/.ngee-build
	echo "Worker-1 AMI ID: "$w1ami | tee -a /home/training/.ngee-build
	echo "Worker-2 AMI ID: "$w2ami | tee -a /home/training/.ngee-build
	echo "Worker-3 AMI ID: "$w3ami | tee -a /home/training/.ngee-build
	echo "Gateway AMI ID: "$gami | tee -a /home/training/.ngee-build
	if [[ "$course" == "CDSW" ]]; then
		echo "CDSW Gateway AMI ID: "$cdswgami | tee -a /home/training/.ngee-build
		echo "CDSW2 AMI ID: "$cdsw2ami | tee -a /home/training/.ngee-build
		echo "Top Level Domain: "$topDomain | tee -a /home/training/.ngee-build
		echo "CDSW TLS Enabled: "$enableTLS | tee -a /home/training/.ngee-build  
	fi
	echo "" | tee -a /home/training/.ngee-build
	echo "Build Number: "$build | tee -a /home/training/.ngee-build

	echo "CM Template: "$cmTemplate | tee -a /home/training/.ngee-build
	echo "CM API Script: "$cmapifile | tee -a /home/training/.ngee-build
	echo  | tee -a /home/training/.ngee-build
	echo "Course: "$course | tee -a /home/training/.ngee-build
	echo "CourseRelease: "$courseRelease | tee -a /home/training/.ngee-build
	echo "CM Version: "$cm_version | tee -a /home/training/.ngee-build
	echo "CM version installed incompatible with build number?: "$incompCmVer
	echo "CDH Version: "$cdhvers | tee -a /home/training/.ngee-build
	echo "CDH version installed incompatible with build number?: "$incompCdhVer

	if [[ "$checkForMultiCustom" == "" ]]; then
		echo "Course Materials File: "$materialsFileName | tee -a /home/training/.ngee-build
		echo "Course-Specific Setup will run? "$runSetup | tee -a /home/training/.ngee-build
	elif [[ "$checkForMultiCustom" != ""  ]]; then
		x="1"
		while [ $x -le $numCourses ]
		do
			echo "Course Materials File $x: "$(cat /home/training/.ngee-courses.txt | grep materialsFileName$x | awk '{print $3}' )| tee -a /home/training/.ngee-build
			echo "Course-Specific Setup will run? "$(cat /home/training/.ngee-courses.txt | grep runSetup$x | awk '{print $3}' ) | tee -a /home/training/.ngee-build
			x=$(( $x + 1 ))	
		done
	else
		echo
	fi
	echo  | tee -a /home/training/.ngee-build
	echo "Cluster Name: "$name | tee -a /home/training/.ngee-build

	echo "cmhost internal IP="$cmhostIp | tee -a /home/training/.ngee-build
}

create_instances() {
	echo "================================================="
	echo "Creating Cluster Instances"
	echo "================================================="

	if [[ "$course" == "CDSW" ]]; then
		workerSize="t2.2xlarge"
	else
		workerSize="t2.large"
	fi
	
	#Static IPs used for Skytap production cluster
	cmhoststaticIP="10.0.0.100"
	m1staticIP="10.0.0.101"
	m2staticIP="10.0.0.102"
	w1staticIP="10.0.0.103"
	w2staticIP="10.0.0.104"
	w3staticIP="10.0.0.105"
	gwstaticIP="10.0.0.106"

	#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
	#m1Instance=$(aws ec2 run-instances --image-id $m1ami --private-ip-address $m1staticIP --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.xlarge --output json)

	#use the following line when creating cluster for AWS production
	m1Instance=$(aws ec2 run-instances --image-id $m1ami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.xlarge --output json)
	m1instanceId=$(echo $m1Instance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
	m1privIP=$(echo $m1Instance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
	#m1pubIP=$(aws ec2 describe-instances --instance-ids $m1instanceId | grep -o '"PublicIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
	if [[ "$m1instanceId" == "" ]]; then
		echo "Error: Failed to launch master-1 instance. This may be a AMI permissions issue. Please consult with your instructor. Exiting."
		exit 1
	fi

	#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
	#m2Instance=$(aws ec2 run-instances --image-id $m2ami --private-ip-address $m2staticIP --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.xlarge --output json)

	#use the following line when creating cluster for AWS production
	m2Instance=$(aws ec2 run-instances --image-id $m2ami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.xlarge --output json)
	m2instanceId=$(echo $m2Instance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
	m2privIP=$(echo $m2Instance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
	if [[ "$m2instanceId" == "" ]]; then
		echo "Error: Failed to launch master-2 instance. This may be a AMI permissions issue. Please consult with your instructor. Exiting."
		exit 1
	fi

	#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
	#w1Instance=$(aws ec2 run-instances --image-id $w1ami --private-ip-address $w1staticIP --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type $workerSize --output json)

	#use the following line when creating cluster for AWS production
	w1Instance=$(aws ec2 run-instances --image-id $w1ami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type $workerSize --output json)
	w1instanceId=$(echo $w1Instance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
	w1privIP=$(echo $w1Instance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
	if [[ "$w1instanceId" == "" ]]; then
		echo "Error: Failed to launch worker-1 instance. This may be a AMI permissions issue. Please consult with your instructor. Exiting."
		exit 1
	fi

	#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
	#w2Instance=$(aws ec2 run-instances --image-id $w2ami --private-ip-address $w2staticIP --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type $workerSize --output json)

	#use the following line when creating cluster for AWS production
	w2Instance=$(aws ec2 run-instances --image-id $w2ami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type $workerSize --output json)
	w2instanceId=$(echo $w2Instance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
	w2privIP=$(echo $w2Instance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
	if [[ "$w2instanceId" == "" ]]; then
		echo "Error: Failed to launch worker-2 instance. This may be a AMI permissions issue. Please consult with your instructor. Exiting."
		exit 1
	fi

	#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
	#w3Instance=$(aws ec2 run-instances --image-id $w3ami --private-ip-address $w3staticIP --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type $workerSize --output json)

	#use the following line when creating cluster for AWS production
	w3Instance=$(aws ec2 run-instances --image-id $w3ami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type $workerSize --output json)
	w3instanceId=$(echo $w3Instance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
	w3privIP=$(echo $w3Instance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
	if [[ "$w3instanceId" == "" ]]; then
		echo "Error: Failed to launch worker-3 instance. This may be a AMI permissions issue. Please consult with your instructor. Exiting."
		exit 1
	fi

	if [[ "$course" == "CDSW" ]]; then
		cdswgInstance=$(aws ec2 run-instances --image-id $cdswgami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type m4.4xlarge --iam-instance-profile Name=$course --output json)
		cdswginstanceId=$(echo $cdswgInstance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
		cdswgprivIP=$(echo $cdswgInstance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
		#cdswgpubIP=$(aws ec2 describe-instances --instance-ids $m1instanceId | grep -o '"PublicIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
		if [[ "$cdswginstanceId" == "" ]]; then
			echo "Error: Failed to launch cdsw-gateway instance. This may be a AMI permissions issue. Please consult with the NGEE team. Exiting."
			exit 1
		fi

		cdsw2Instance=$(aws ec2 run-instances --image-id $cdsw2ami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.2xlarge --iam-instance-profile Name=$course --output json)
		cdsw2instanceId=$(echo $cdsw2Instance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
		cdsw2privIP=$(echo $cdsw2Instance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
		#cdswgpubIP=$(aws ec2 describe-instances --instance-ids $m1instanceId | grep -o '"PublicIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
		if [[ "$cdsw2instanceId" == "" ]]; then
			echo "Error: Failed to launch cdsw2 instance. This may be a AMI permissions issue. Please consult with the NGEE team. Exiting."
			exit 1
		fi
	fi

	if [[ "$course" != "None" && "$checkForMultiCustom" == "" ]]; then
		#As long as course is not "None", and it is not a multi-course custom course then create the instance with the needed IAM role

		#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
		#gInstance=$(aws ec2 run-instances --image-id $gami  --private-ip-address $gwstaticIP --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.large --iam-instance-profile Name=$course  --output json)

		#use the following line when creating cluster for AWS production
		gInstance=$(aws ec2 run-instances --image-id $gami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.large --iam-instance-profile Name=$course  --output json)

	else
		echo "No IAM role will be assigned to the gateway node for now."
		 
		#static IP - uncomment following line when creating cluster for Skytap production, and comment out the AWS production line
		#gInstance=$(aws ec2 run-instances --image-id $gami --subnet-id $subnetId --private-ip-address $gwstaticIP --security-group-ids $sgId --count 1 --instance-type t2.large --output json)
		
		#use the following line when creating cluster for AWS production
		gInstance=$(aws ec2 run-instances --image-id $gami --subnet-id $subnetId --security-group-ids $sgId --count 1 --instance-type t2.large --output json)
	fi
	ginstanceId=$(echo $gInstance | grep -o '"InstanceId": "[^"]*' | grep -o '[^"]*$' | head -1)
	gprivIP=$(echo $gInstance | grep -o '"PrivateIpAddress": "[^"]*' | grep -o '[^"]*$' | head -1)	

	#verify the instances were created

	#write instanceIds to disk
	echo "m1instanceId "$m1instanceId > /home/training/.ngee-instances
	echo "m2instanceId "$m2instanceId >> /home/training/.ngee-instances
	echo "w1instanceId "$w1instanceId >> /home/training/.ngee-instances
	echo "w2instanceId "$w2instanceId >> /home/training/.ngee-instances
	echo "w3instanceId "$w3instanceId >> /home/training/.ngee-instances
	echo "ginstanceId "$ginstanceId >> /home/training/.ngee-instances

	if [[ "$course" == "CDSW" ]]; then
		echo "cdswginstanceId "$cdswginstanceId >> /home/training/.ngee-instances
		echo "cdsw2instanceId "$cdsw2instanceId >> /home/training/.ngee-instances
	fi

	m1Id=$(cat /home/training/.ngee-instances | grep m1instanceId | awk '{print $2}')
	m2Id=$(cat /home/training/.ngee-instances | grep m2instanceId | awk '{print $2}')
	w1Id=$(cat /home/training/.ngee-instances | grep w1instanceId | awk '{print $2}')
	w2Id=$(cat /home/training/.ngee-instances | grep w2instanceId | awk '{print $2}')
	w3Id=$(cat /home/training/.ngee-instances | grep w3instanceId | awk '{print $2}')
	gwId=$(cat /home/training/.ngee-instances | grep ginstanceId | awk '{print $2}')

	if [[ "$m1Id" == "" || "$m2Id" == "" || "$w1Id" == "" || "$w2Id" == "" || "$w3Id" == "" || "$gwId" == "" || "$m1Id" == "NULL" || "$m2Id" == "NULL" || "$w1Id" == "NULL" || "$w2Id" == "NULL" || "$w3Id" == "NULL" || "$gwId" == "NULL" ]]; then
		echo "Error creating all AWS instances. "
		echo "Please run create-instances.sh again. Exiting."
		exit 1
	fi


	#tag instances
#	sleep 20
	count=0
	while [ $count -lt 20 ];
	do
		count=$(( $count + 1 ))
		printf "."
		sleep 1
	done
	printf "\n"
	echo 
	#echo "Tagging instances..."
	aws ec2 create-tags --resources $m1instanceId --tags Key=Name,Value=$nameTag-$name-master-1 --output json
	aws ec2 create-tags --resources $m2instanceId --tags Key=Name,Value=$nameTag-$name-master-2 --output json
	aws ec2 create-tags --resources $w1instanceId --tags Key=Name,Value=$nameTag-$name-worker-1 --output json
	aws ec2 create-tags --resources $w2instanceId --tags Key=Name,Value=$nameTag-$name-worker-2 --output json
	aws ec2 create-tags --resources $w3instanceId --tags Key=Name,Value=$nameTag-$name-worker-3 --output json
	aws ec2 create-tags --resources $ginstanceId --tags Key=Name,Value=$nameTag-$name-gateway --output json

	aws ec2 create-tags --resources $instanceId --tags Key=Name,Value=$nameTag-$name-cmhost --output json

	if [[ "$course" == "CDSW" ]]; then
		aws ec2 create-tags --resources $cdswginstanceId --tags Key=Name,Value=$nameTag-$name-cdsw-gateway --output json
		aws ec2 create-tags --resources $cdsw2instanceId --tags Key=Name,Value=$nameTag-$name-cdsw2 --output json
	fi

	#verify status checks before continuing on
	vResp=0
	count=0
	echo "Instances launching. Waiting for them to pass all status checks..."
	echo
	echo "This step typically takes 3 or 4 minutes, sometimes longer. Please be patient..."
  	while [ $vResp -eq 0 ] 
  	do 
		currentStatus=$(aws ec2 describe-instance-status --instance-ids $m1instanceId $m2instanceId $w1instanceId $w2instanceId $w3instanceId $ginstanceId --output json | grep -o '"Status": "[^"]*' | grep -o '[^"]*$')
		c1=$(echo $currentStatus | awk '{print $1}')
		c2=$(echo $currentStatus | awk '{print $2}')
		c3=$(echo $currentStatus | awk '{print $3}')
		c4=$(echo $currentStatus | awk '{print $4}')
		c5=$(echo $currentStatus | awk '{print $5}')
		c6=$(echo $currentStatus | awk '{print $6}')
		c7=$(echo $currentStatus | awk '{print $7}')
		c8=$(echo $currentStatus | awk '{print $8}')
		c9=$(echo $currentStatus | awk '{print $9}')
		c10=$(echo $currentStatus | awk '{print $10}')
		c11=$(echo $currentStatus | awk '{print $11}')
		c12=$(echo $currentStatus | awk '{print $12}')
		if [[ "$c1" == "ok" ]] && [[ "$c2" == "passed" ]] && [[ "$c3" == "ok" ]] && [[ "$c4" == "passed" ]] && \
		   [[ "$c5" == "ok" ]] && [[ "$c6" == "passed" ]] && [[ "$c7" == "ok" ]] && [[ "$c8" == "passed" ]] && \
		   [[ "$c9" == "ok" ]] && [[ "$c10" == "passed" ]] && [[ "$c11" == "ok" ]] && [[ "$c12" == "passed" ]]; then 
				printf "\n"
				echo "All instances now responsive, moving on..."
				vResp=1
		else
			#sleep 15 seconds
			count=0
			while [ $count -lt 15 ];
			do
				count=$(( $count + 1))
				printf "."
				sleep 1
			done
		fi
	done
}

verify_cdsw_instances(){
	if [[ "$course" == "CDSW" ]]; then
		#verify status checks before continuing on
		cvResp=0
		ccount=0
		echo "Verifying the two CDSW instances also passed all status checks..."
	  	while [ $cvResp -eq 0 ] 
	  	do 
			ccurrentStatus=$(aws ec2 describe-instance-status --instance-ids $cdswginstanceId $cdsw2instanceId  --output json | grep -o '"Status": "[^"]*' | grep -o '[^"]*$')
			echo $ccurrentStatus
			c13=$(echo $ccurrentStatus | awk '{print $1}')
			c14=$(echo $ccurrentStatus | awk '{print $2}')
			c15=$(echo $ccurrentStatus | awk '{print $3}')
			c16=$(echo $ccurrentStatus | awk '{print $4}')
			
			if [[ "$c13" == "ok" ]] && [[ "$c14" == "passed" ]] && [[ "$c15" == "ok" ]] && [[ "$c16" == "passed" ]]; then 
					echo "Both CDSW instances are responsive, moving on..."
					cvResp=1
			else
				# sleep 15 seconds
				ccount=0
				while [ $ccount -lt 15 ];
				do
					ccount=$(( $ccount + 1 ))
					printf "."
					sleep 1
				done
			fi
		done
	else
		echo
	fi
}

config_networking() {
	#config cmhost /etc/hosts
	if [[ "$course" == "CDSW" ]]; then
		sudo rm -rf /etc/NetworkManager/dispatcher.d/updatecmhost
		echo
		echo "Updating /etc/hosts on cmhost for CDSW cluster"

		#cmprivIP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

		if [[ "$name" == "cluster1" || "$name" == "cluster2" || "$name" == "dev" ]]; then
			sudo sh -c "echo $cmhostIp cmhost.$name.$topDomain cmhost >> /etc/hosts"
			sudo sed -i '/cmhost.example.com/d' /etc/hosts
			sudo sh -c "echo $m1privIP master-1.$name.$topDomain master-1 >> /etc/hosts"
			sudo sh -c "echo $m2privIP master-2.$name.$topDomain master-2 >> /etc/hosts"
			sudo sh -c "echo $w1privIP worker-1.$name.$topDomain worker-1 >> /etc/hosts"
			sudo sh -c "echo $w2privIP worker-2.$name.$topDomain worker-2 >> /etc/hosts"
			sudo sh -c "echo $w3privIP worker-3.$name.$topDomain worker-3 >> /etc/hosts"
			sudo sh -c "echo $gprivIP gateway.$name.$topDomain gateway >> /etc/hosts"
			sudo sh -c "echo $cdswgprivIP cdsw-gateway.$name.$topDomain cdsw-gateway >> /etc/hosts"
			sudo sh -c "echo $cdsw2privIP cdsw2.$name.$topDomain cdsw2 >> /etc/hosts"
		else
			sudo sh -c "echo $cmhostIp cmhost.$topDomain cmhost >> /etc/hosts"
			sudo sed -i '/cmhost.example.com/d' /etc/hosts
			sudo sh -c "echo $m1privIP master-1.$topDomain master-1 >> /etc/hosts"
			sudo sh -c "echo $m2privIP master-2.$topDomain master-2 >> /etc/hosts"
			sudo sh -c "echo $w1privIP worker-1.$topDomain worker-1 >> /etc/hosts"
			sudo sh -c "echo $w2privIP worker-2.$topDomain worker-2 >> /etc/hosts"
			sudo sh -c "echo $w3privIP worker-3.$topDomain worker-3 >> /etc/hosts"
			sudo sh -c "echo $gprivIP gateway.$topDomain gateway >> /etc/hosts"
			sudo sh -c "echo $cdswgprivIP cdsw-gateway.$topDomain cdsw-gateway >> /etc/hosts"
			sudo sh -c "echo $cdsw2privIP cdsw2.$topDomain cdsw2 >> /etc/hosts"
		fi
	else
		echo
		echo "updating /etc/hosts on cmhost"
		sudo sh -c "echo $m1privIP master-1.example.com master-1 >> /etc/hosts"
		sudo sh -c "echo $m2privIP master-2.example.com master-2 >> /etc/hosts"
		sudo sh -c "echo $w1privIP worker-1.example.com worker-1 >> /etc/hosts"
		sudo sh -c "echo $w2privIP worker-2.example.com worker-2 >> /etc/hosts"
		sudo sh -c "echo $w3privIP worker-3.example.com worker-3 >> /etc/hosts"
		sudo sh -c "echo $gprivIP gateway.example.com gateway >> /etc/hosts"
	fi

	sudo service dnsmasq stop
	sudo chkconfig dnsmasq off

	if [[ "$course" == "CDSW" ]]; then
		echo
		echo "Copying hosts to cdsw nodes"
		sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@cdsw-gateway:/etc/
		sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@cdsw2:/etc/
		echo
		echo "Updating hostname on cdsw-gateway and cdsw2"
		ssh $nocheck -t training@cdsw-gateway sudo sh -c "hostnamectl set-hostname cdsw-gateway"
		ssh $nocheck -t training@cdsw-gateway sudo sed -i 's/.foo.duocar.us//g' /etc/hostname
		ssh $nocheck -t training@cdsw-gateway sudo rm /etc/dhcp/dhclient-eth0.conf
		ssh $nocheck -t training@cdsw2 sudo sh -c "hostnamectl set-hostname cdsw2"
		ssh $nocheck -t training@cdsw2 sudo sed -i 's/.foo.duocar.us//g' /etc/hostname
		ssh $nocheck -t training@cdsw2 sudo rm /etc/dhcp/dhclient-eth0.conf
		sleep 10
		echo
		echo "Updating agents on cdsw nodes with location of cmhost"
		ssh $nocheck -t training@cdsw-gateway sudo sed -i 's/server_host=localhost/server_host=cmhost/' /etc/cloudera-scm-agent/config.ini
		ssh $nocheck -t training@cdsw2 sudo sed -i 's/server_host=localhost/server_host=cmhost/' /etc/cloudera-scm-agent/config.ini
		echo
		echo "Rebooting the two CDSW nodes now..."
		ssh $nocheck -t training@cdsw-gateway sudo init 6
		ssh $nocheck -t training@cdsw2 sudo init 6
		verify_cdsw_instances
	fi

	#config other nodes to find cmhost
	echo "Copying /etc/hosts to other nodes..."
	sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@master-1:/etc/
	sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@master-2:/etc/
	sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@worker-1:/etc/
	sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@worker-2:/etc/
	sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@worker-3:/etc/
	sudo scp -i /root/.ssh/id_rsa $nocheck /etc/hosts root@gateway:/etc/
}

start_cmagents() {
	echo "Starting CM agents on all nodes..."
	#sudo service cloudera-scm-agent restart
	ssh $nocheck training@master-1 sudo service cloudera-scm-agent start
	ssh $nocheck training@master-2 sudo service cloudera-scm-agent start
	ssh $nocheck training@worker-1 sudo service cloudera-scm-agent start
	ssh $nocheck training@worker-2 sudo service cloudera-scm-agent start
	ssh $nocheck training@worker-3 sudo service cloudera-scm-agent start
	ssh $nocheck training@gateway sudo service cloudera-scm-agent start
	
	echo "Pausing 30 seconds to allow cm agents to heartbeat to cm server..."

	#sleep 30
	count=0
	while [ $count -lt 30 ];
	do
		count=$(( $count + 1 ))
		printf "."
		sleep 1
	done
	printf " \n "
}

verify_cmserver() {
	echo "Verifying CM Server status"

	status=$(sudo service cloudera-scm-server status | cut -d ' ' -f6)
	if [[ "$status" == "running..." ]]; then
		echo "CM Server is running"
	else
		echo "CM Server is not running. Starting it now."
		sudo service cloudera-scm-server start
		#sleep 30 seconds
		count=0
		while [ $count -lt 30 ];
		do
			count=$(( $count + 1 ))
			printf "."
			sleep 1
		done
		printf " \n "
		
		#check if start command fixed the issue, if not, fail.
		status=$(sudo service cloudera-scm-server status | cut -d ' ' -f6)
		if [[ "$status" == "running..." ]]; then
		echo "CM Server is running"
	    else
	    	echo "CM Server is still not running. Exiting. Please run the following commands then rerun create-cluster.sh."
	    	echo
	    	echo "    $ sudo service cloudera-scm-server start"
	    	echo "    $ sudo service cloudera-scm-server status"
	    	echo
	    	exit 1
	    fi
	fi

}

config_all_hosts(){
	echo "Configuring Java home for all nodes"

	mkdir /home/training/working

	cat <<-EOT > /home/training/working/allHostsConfig.json
{
	"items" : [  { 
        "name" : "java_home",
        "value" : "/usr/java/jdk1.8.0_111"
    }, {
        "name" : "host_clock_offset_thresholds",
        "value" : "{\"warning\":3000,\"critical\":30000}"
    }]
}
EOT
	callCmApi http://localhost:7180/api/v10/cm/allHosts/config PUT "-d @/home/training/working/allHostsConfig.json"
	echo
	echo "Restarting Cloudera Management Service"
	echo
  	curl -s -X POST -H "Content-Type:application/json" -u admin:admin http://cmhost:7180/api/v12/cm/service/commands/restart 2>/dev/null
  	
	echo "Waiting 90 seconds to allow it time to finish starting..."
    while [ $count -lt 30 ];
    do
      count=$(( $count + 1))
      printf "."
      sleep 1
    done

}

cdsw_configs() {
	if [[ "$course" == "CDSW" ]]; then
		echo "================================================="
		echo "Configuring CDSW Cluster"
		echo "================================================="

		echo "Creating new Route53 entries..."

		#collect public IP info
		echo
		cdswPubIP=$(aws ec2 describe-instances --instance-id $(cat /home/training/.ngee-instances|grep cdswginstanceId|awk '{print $2}') --output json | grep PublicIpAddress | cut -d '"' -f4 )
		echo "cdswPubIP="$cdswPubIP
		cdsw2PubIP=$(aws ec2 describe-instances --instance-id $(cat /home/training/.ngee-instances|grep cdsw2instanceId|awk '{print $2}') --output json | grep PublicIpAddress | cut -d '"' -f4 )
		echo "cdsw2PubIP="$cdsw2PubIP
		m1PubIP=$(aws ec2 describe-instances --instance-id $(cat /home/training/.ngee-instances|grep m1instanceId|awk '{print $2}') --output json | grep PublicIpAddress | cut -d '"' -f4 )
		echo "m1PubIP="$m1PubIP

		#update the json files to be passed
		mkdir -p /home/training/config/working
		cp /home/training/config/route53-recordset.json /home/training/config/working/route53-recordset.json 
		cp /home/training/config/route53-recordset2.json /home/training/config/working/route53-recordset2.json 
		cp /home/training/config/route53-recordset3.json /home/training/config/working/route53-recordset3.json 
		cp /home/training/config/route53-recordset4.json /home/training/config/working/route53-recordset4.json 
		cp /home/training/config/route53-recordset5.json /home/training/config/working/route53-recordset5.json 
		cp /home/training/config/route53-recordset6.json /home/training/config/working/route53-recordset6.json 
		cp /home/training/config/route53-recordset7.json /home/training/config/working/route53-recordset7.json 
		cp /home/training/config/route53-recordset8.json /home/training/config/working/route53-recordset8.json 
		cp /home/training/config/route53-recordset9.json /home/training/config/working/route53-recordset9.json 
		cp /home/training/config/route53-recordset10.json /home/training/config/working/route53-recordset10.json 
		cp /home/training/config/route53-recordset11.json /home/training/config/working/route53-recordset11.json 

		sed -i 's/replace-cdsw-public-ip/'"$cdswPubIP"'/g' /home/training/config/working/route53-recordset.json 
		sed -i 's/replace-cdsw-public-ip/'"$cdswPubIP"'/g' /home/training/config/working/route53-recordset2.json 
		sed -i 's/replace-master-1-public-ip/'"$m1PubIP"'/g' /home/training/config/working/route53-recordset3.json 
		sed -i 's/replace-cdsw2-public-ip/'"$cdsw2PubIP"'/g' /home/training/config/working/route53-recordset4.json 
		sed -i 's/replace-master-1-public-ip/'"$m1PubIP"'/g' /home/training/config/working/route53-recordset5.json
		sed -i 's/replace-master-1-private-ip/'"$m1privIP"'/g' /home/training/config/working/route53-recordset6.json 
		sed -i 's/replace-master-2-private-ip/'"$m2privIP"'/g' /home/training/config/working/route53-recordset7.json 
		sed -i 's/replace-worker-1-private-ip/'"$w1privIP"'/g' /home/training/config/working/route53-recordset8.json 
		sed -i 's/replace-worker-2-private-ip/'"$w2privIP"'/g' /home/training/config/working/route53-recordset9.json 
		sed -i 's/replace-worker-3-private-ip/'"$w3privIP"'/g' /home/training/config/working/route53-recordset10.json  
		sed -i 's/replace-gateway-private-ip/'"$gprivIP"'/g' /home/training/config/working/route53-recordset11.json 

		if [[ "$name" == "dev" || "$name" == "cluster1" || "$name" == "cluster2" ]]; then
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset.json 
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset2.json 
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset3.json 
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset4.json 
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset5.json 
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset6.json
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset7.json
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset8.json
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset9.json
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset10.json
			sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/config/working/route53-recordset11.json
		else
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset.json 
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset2.json 
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset3.json 
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset4.json 
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset5.json 
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset6.json
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset7.json
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset8.json
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset9.json
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset10.json
			sed -i 's/replace-cluster-name.//g' /home/training/config/working/route53-recordset11.json
		fi			

		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset.json 
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset2.json 
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset3.json 
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset4.json 
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset5.json 
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset6.json
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset7.json
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset8.json
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset9.json
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset10.json
		sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/config/working/route53-recordset11.json

		cd /home/training/config/working

		#The test if route53 entries already exist was done earlier in this script
		if [[ "$r53exist" == "" ]]; then
			#no entries currently exist, so create them now
			result=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset.json --output text | awk '{print $1}')
			if [[ "$result" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 cdsw-gateway record for this cluster failed. Be sure your cmhost has the CDSWcmhostRole IAM role. Exiting create-cluster script."
				exit 
			fi
			result2=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset2.json --output text | awk '{print $1}')
			if [[ "$result2" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 wildcard record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result3=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset3.json --output text | awk '{print $1}')
			if [[ "$result3" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 Hue record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result4=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset4.json --output text | awk '{print $1}')
			if [[ "$result4" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 cdsw2 record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result5=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset5.json --output text | awk '{print $1}')
			if [[ "$result5" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 Spark History Server record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result6=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset6.json --output text | awk '{print $1}')
			if [[ "$result6" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 master-1 record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result7=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset7.json --output text | awk '{print $1}')
			if [[ "$result7" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 master-2 record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result8=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset8.json --output text | awk '{print $1}')
			if [[ "$result8" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 worker-1 record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result9=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset9.json --output text | awk '{print $1}')
			if [[ "$result9" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 worker-2 record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result10=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset10.json --output text | awk '{print $1}')
			if [[ "$result10" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 worker-3 record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			result11=$(aws route53 change-resource-record-sets --hosted-zone-id Z7FS6V9NOBNJY --change-batch file://route53-recordset11.json --output text | awk '{print $1}')
			if [[ "$result11" != "CHANGEINFO" ]]; then
				echo "ERROR: attempt to create route 53 gateway record for this cluster failed. Exiting create-cluster script."
				exit 
			fi
			echo "Done creating new Route53 entries."
		else
			#users will only get here if they indicated earlier that they want the existing entries updated to point to this new cluster.
			echo 
			echo "Updating existing route53 entries to point to this cluster"
			/home/training/config/update-route53.sh

		fi

		cd /home/training

		#collect private IPs
		cdswPrivIp=$(cat /etc/hosts|grep cdsw-gateway|awk '{print $1}')
		cdsw2PrivIp=$(cat /etc/hosts|grep cdsw2|awk '{print $1}')
  		echo
		#previously we did not have the duocar.us (FQDN) as part of the hostname
		echo "Updating the hostnames on cdsw-gateway and cdsw2"
		if [[ "$name" == "dev" || "$name" == "cluster1" || "$name" == "cluster2" ]]; then

			ssh $nocheck -t training@cdsw-gateway sudo /usr/bin/hostnamectl set-hostname cdsw-gateway.$name.$topDomain
			ssh $nocheck -t training@cdsw2 sudo /usr/bin/hostnamectl set-hostname cdsw2.$name.$topDomain

			echo
			echo "Adding $topDomain to search string in /etc/resolv.conf"
			ssh $nocheck -t training@cdsw-gateway sudo cp /etc/resolv.conf /tmp/
			ssh $nocheck -t training@cdsw-gateway sudo sed -i '/search/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw-gateway sudo sed -i '/generated/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw-gateway sudo "sed -i '1i\search $region.compute.internal $name.$topDomain' /etc/resolv.conf"

			ssh $nocheck -t training@cdsw2 sudo cp /etc/resolv.conf /tmp/
			ssh $nocheck -t training@cdsw2 sudo sed -i '/search/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw2 sudo sed -i '/generated/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw2 sudo "sed -i '1i\search $region.compute.internal $name.$topDomain' /etc/resolv.conf"
		else
			ssh $nocheck -t training@cdsw-gateway sudo /usr/bin/hostnamectl set-hostname cdsw-gateway.$topDomain
			ssh $nocheck -t training@cdsw2 sudo /usr/bin/hostnamectl set-hostname cdsw2.$topDomain

			echo
			echo "Adding $topDomain to search string in /etc/resolv.conf"
			ssh $nocheck -t training@cdsw-gateway sudo cp /etc/resolv.conf /tmp/
			ssh $nocheck -t training@cdsw-gateway sudo sed -i '/search/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw-gateway sudo sed -i '/generated/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw-gateway sudo "sed -i '1i\search $region.compute.internal $topDomain' /etc/resolv.conf"

			ssh $nocheck -t training@cdsw2 sudo cp /etc/resolv.conf /tmp/
			ssh $nocheck -t training@cdsw2 sudo sed -i '/search/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw2 sudo sed -i '/generated/d' /etc/resolv.conf
			ssh $nocheck -t training@cdsw2 sudo "sed -i '1i\search $region.compute.internal $topDomain' /etc/resolv.conf"
		fi

		echo
		echo "Adding Anaconda to PATH on two cdsw nodes"
		ssh $nocheck -t training@cdsw-gateway "echo export PATH=/opt/cloudera/parcels/Anaconda/bin:$PATH | sudo tee --append /home/training/.bashrc"
		ssh $nocheck -t training@cdsw2 "echo export PATH=/opt/cloudera/parcels/Anaconda/bin:$PATH | sudo tee --append /home/training/.bashrc"
		echo

		#stop the cron job service so it doesn't prematurely create hue accounts
		ssh $nocheck -t training@cdsw-gateway sudo systemctl stop crond

		#copy over hue account creation files
		sudo scp -i /root/.ssh/id_rsa $nocheck /home/training/config/create-hue-users.sh training@cdsw-gateway:/home/training/
		ssh $nocheck -t training@cdsw-gateway sudo chown training:training /home/training/create-hue-users.sh
		sudo scp -i /root/.ssh/id_rsa $nocheck /home/training/config/crontab root@cdsw-gateway:/etc/
		ssh $nocheck -t training@cdsw-gateway sudo chown root:root /etc/crontab

		ssh $nocheck -t training@cdsw-gateway sudo service cloudera-scm-agent start
		ssh $nocheck -t training@cdsw2 sudo service cloudera-scm-agent start 

		if [[ "$enableTLS" == "Y" ]]; then
			echo "Enabling CDSW TLS..."
			ssh $nocheck -t training@cdsw-gateway mkdir /home/training/certs
			
			#download needed files
			aws s3 cp s3://cdswcerts/star_cdsw-gateway_"$name"_duocar_us.crt .
			aws s3 cp s3://cdswcerts/star_cdsw-gateway_"$name"_duocar_us.key .
			aws s3 cp s3://cdswcerts/DigiCertCA.crt .
			chmod 444 star_cdsw-gateway_"$name"_duocar_us.key
			chmod 644 star_cdsw-gateway_"$name"_duocar_us.crt
			chmod 644 DigiCertCA.crt
			
			#copy to cdsw-gateway
			scp -i /home/training/.ssh/id_rsa $nocheck -r star_cdsw-gateway* training@cdsw-gateway:/home/training/certs/
			scp -i /home/training/.ssh/id_rsa $nocheck DigiCertCA.crt training@cdsw-gateway:/home/training/certs/

			#disable ssh over 443 on cdsw-gateway to avoid bind conflict
			ssh $nocheck -t training@cdsw-gateway sudo sed -i 's/"Port 443"/"#Port 443"/' /etc/ssh/sshd_config
			ssh $nocheck -t training@cdsw-gateway sudo service sshd restart

			echo
			echo "Enabling Hue TLS..."
			aws s3 cp s3://cdswcerts/star_cdsw-gateway_"$name"_duocar_us.pem .
			aws s3 cp s3://cdswcerts/star_cdsw-gateway_"$name"_duocar_us-key.pem .
			ssh $nocheck root@master-1 mkdir -p /etc/hue
			scp -i /home/training/.ssh/id_rsa $nocheck -r star_cdsw-gateway* root@master-1:/etc/hue/
			scp -i /home/training/.ssh/id_rsa $nocheck DigiCertCA.crt root@master-1:/etc/hue/
		fi

		#remove entries from /etc/fstab
		echo
		echo "Ensuring that fstab does not have entries for xvdb and xvdc"
		ssh $nocheck -t training@cdsw-gateway sudo sed -i '/xvdb/d' /etc/fstab
		ssh $nocheck -t training@cdsw-gateway sudo sed -i '/xvdc/d' /etc/fstab
		ssh $nocheck -t training@cdsw2 sudo sed -i '/xvdb/d' /etc/fstab
		ssh $nocheck -t training@cdsw2 sudo sed -i '/xvdc/d' /etc/fstab

		#set swappiness on cdsw-gateway
		echo
		echo "Updating swappiness settings"
		ssh $nocheck -t training@cdsw-gateway "echo 10 | sudo tee -a /proc/sys/vm/swappiness"
		ssh $nocheck -t training@cdsw-gateway sudo sysctl vm.swappiness=10
		ssh $nocheck -t training@cdsw-gateway sudo sed -i '/swappiness/d' /etc/sysctl.conf
		ssh $nocheck -t training@cdsw-gateway "echo vm.swappiness=10 | sudo tee -a /etc/sysctl.conf"

		ssh $nocheck -t training@cdsw-gateway sudo sed -i '/net.ipv6.conf.all.disable/d' /etc/sysctl.conf
		ssh $nocheck -t training@cdsw-gateway "echo net.ipv6.conf.all.disable=1 | sudo tee -a /etc/sysctl.conf"
		ssh $nocheck -t training@cdsw-gateway sudo sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
		ssh $nocheck -t training@cdsw-gateway "echo net.ipv6.conf.all.disable_ipv6=0 | sudo tee -a  /etc/sysctl.conf"

		#set swappiness on cdsw2
		ssh $nocheck -t training@cdsw2 "echo 10 | sudo tee -a /proc/sys/vm/swappiness"
		ssh $nocheck -t training@cdsw2 sudo sysctl vm.swappiness=10
		ssh $nocheck -t training@cdsw2 sudo sed -i '/swappiness/d' /etc/sysctl.conf
		ssh $nocheck -t training@cdsw2 "echo vm.swappiness=10 | sudo tee -a /etc/sysctl.conf"

		ssh $nocheck -t training@cdsw2 sudo sed -i '/net.ipv6.conf.all.disable/d' /etc/sysctl.conf
		ssh $nocheck -t training@cdsw2 "echo net.ipv6.conf.all.disable=1 | sudo tee -a /etc/sysctl.conf"
		ssh $nocheck -t training@cdsw2 sudo sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
		ssh $nocheck -t training@cdsw2 "echo net.ipv6.conf.all.disable_ipv6=0 | sudo tee -a  /etc/sysctl.conf"

		echo
		echo "Setting the clock to use chronyd instead of ntpd"
		#ssh $nocheck -t training@cdsw-gateway sudo systemctl disable ntpdate 
		#ssh $nocheck -t training@cdsw-gateway sudo systemctl stop ntpdate 
		#ssh $nocheck -t training@cdsw-gateway sudo systemctl disable ntpd
		#ssh $nocheck -t training@cdsw-gateway sudo systemctl stop ntpd
		ssh $nocheck -t training@cdsw-gateway sudo systemctl enable chronyd
		ssh $nocheck -t training@cdsw-gateway sudo systemctl restart chronyd

		#ssh $nocheck -t training@cdsw2 sudo systemctl disable ntpdate 
		#ssh $nocheck -t training@cdsw2 sudo systemctl stop ntpdate 
		#ssh $nocheck -t training@cdsw2 sudo systemctl disable ntpd
		#ssh $nocheck -t training@cdsw2 sudo systemctl stop ntpd
		ssh $nocheck -t training@cdsw2 sudo systemctl enable chronyd
		ssh $nocheck -t training@cdsw2 sudo systemctl restart chronyd

		#verify cm server and cm agents are running, and cm mgmt services are healthy
		./config/reset-cm.sh

	else
		echo
	fi

}

apply_cm_template(){
	echo "================================================="
	echo "Creating CDH Cluster"
	echo "================================================="
	echo 
	echo "Applying cluster template via CM API..."
	
	#configure the cm-template so that the cluster name will be used
	mkdir -p /home/training/working
	cp /home/training/$cmTemplate /home/training/working/$cmTemplate
	sed -i 's/replace-display-name/'"$name"'/g' /home/training/working/$cmTemplate
	sed -i 's/replace-top-domain/'"$topDomain"'/g' /home/training/working/$cmTemplate

	if [[ "$name" == "cluster1" || "$name" == "cluster2" || "$name" == "dev" ]]; then
		sed -i 's/replace-cluster-name/'"$name"'/g' /home/training/working/$cmTemplate
	else
		sed -i 's/replace-cluster-name.//g' /home/training/working/$cmTemplate
	fi

	#callCmApi http://localhost:7180/api/v12/cm/importClusterTemplate POST "-d @/home/training/working/$cmTemplate"
	url="http://localhost:7180/api/v12/cm/importClusterTemplate"
	passJson="-d @/home/training/working/$cmTemplate"
	respo=$(curl -s -X POST -H "Content-Type:application/json" -u admin:admin $url $passJson)
	echo "Starting import - API response:"
	#echo $respo
	procId=$(echo $respo | awk '{print $4}' | sed 's/,//') 
	
	echo 
	echo "NOTE: This will take five to ten minutes to complete. Please be patient."
	echo 

	#verify status 
	xvResp=0
	xcount=0
	while [ $xvResp -eq 0 ] 
	do 
		#wait for the import to complete
		status=$(curl -s -X GET -H "Content-Type:application/json" -u admin:admin http://localhost:7180/api/v1/commands/$procId |grep active)
		s1=$(echo $status |awk '{print $3}'|sed s/,//)
		
		if [[ "$s1" == "false" ]]; then 
			printf "\n"
			echo "The template import command has completed. Verifying successful import."
			echo
			#check if the import succeeded
			tresult=$(curl -s -X GET -H "Content-Type:application/json" -u admin:admin http://localhost:7180/api/v1/commands/$procId |grep '"success"')
			t1=$(echo $tresult |awk '{print $3}'|sed s/,// )
			
			if [[ "$t1" == "true" ]]; then 
				echo "Cluster template import was successful. "
				echo
				xvResp=1
			else
				echo
				echo "ERROR: The template did not import successfully."
				echo 
				echo "Please re-run create-cluster.sh. Exiting."
				exit 1
			fi
		else
			#import is still in progress
			xcount=0
			while [ $xcount -lt 15 ];
			do
				xcount=$(( $xcount +1 ))
				printf "."
				sleep 1
			done
		fi
	done
}

call_cm_api() {
	echo "================================================="
	echo "Running CM API Script"
	echo "================================================="
	cd /home/training/config 
	sudo ./$cmapifile

	if [[ "$course" == "CDSW" ]]; then
		echo
		#echo "Installing CDSW on the cdsw-gateway node. This may take 10 minutes or more."	
		#need an expect script here
		#ssh $nocheck training@cdsw-gateway sudo cdsw init
	fi
}

custom_course(){
	ssh $nocheck training@gateway cp /home/training/config/update-s3-creds.sh /home/training/config/update-s3-creds.sh.backup
	ssh $nocheck training@gateway cp /home/training/config/get_training_materials.sh /home/training/config/get_training_materials.sh.backup
	y="1"
	while [ $y -le $numCourses ]
	do
		echo "In custom_course function"
		echo "y="$y
		#apply the IAM Role to the gateway
		iamRoleToAssign=$(cat /home/training/.ngee-courses.txt | grep courseAbbr$y | awk '{print $3}')
		echo "iamRoleToAssign="$iamRoleToAssign
		materialsFileName=$(cat /home/training/.ngee-courses.txt | grep materialsFileName$y | awk '{print $3}')
		echo "materialsFileName="$materialsFileName
		runSetup=$(cat /home/training/.ngee-courses.txt | grep runSetup$y | awk '{print $3}')
		echo "runSetup="$runSetup

		echo
		echo "Applying IAM role to gateway instance"
		if [[ "$y" == "1" ]]; then
			iamRoleApply=$(aws ec2 associate-iam-instance-profile --instance-id $ginstanceId --iam-instance-profile Name=$iamRoleToAssign --output json)
		else
			echo "finding exising association-id"
			currentAssoc=$(aws ec2 describe-iam-instance-profile-associations --association-ids --filters Name=instance-id,Values=$ginstanceId --output json  | grep AssociationId | awk '{print $2}'| sed 's/"//g' |sed 's/,//g')
			echo "replaceing iam role on gateway"
			iamRoleApply=$(aws ec2 replace-iam-instance-profile-association --iam-instance-profile Name=$iamRoleToAssign --association-id $currentAssoc --output json)
		fi
		echo "Result of iamRoleApply:"$iamRoleApply
		echo "Sleeping 15 seconds for role apply..."
		sleep 15 #give it time to take?

		course=$iamRoleToAssign
		echo "course="$course
		echo "acquiring fresh update-s3-creds.sh file on gateway"
		ssh $nocheck training@gateway rm /home/training/config/update-s3-creds.sh
		ssh $nocheck training@gateway cp /home/training/config/update-s3-creds.sh.backup /home/training/config/update-s3-creds.sh
		echo "acquiring fresh get_training_materials.sh file on gateway"
		ssh $nocheck training@gateway rm /home/training/config/get_training_materials.sh 
		ssh $nocheck training@gateway cp /home/training/config/get_training_materials.sh.backup /home/training/config/get_training_materials.sh 

		#update the IAM credentials
		echo "Calling config_s3_access"
		config_S3_access
		config_course

		y=$(( $y + 1 ))	
	done

}
config_S3_access(){
	echo ""
	echo "Configuring access to S3 directory for course from gateway node."

	lowercaseCourse=$(echo $course | sed -e 's/\(.*\)/\L\1/')
	
	ssh $nocheck training@gateway sed -i s/replace-gateway-iam-role/"$course"/g /home/training/config/update-s3-creds.sh 

	ssh $nocheck training@gateway sed -i s/replace-gateway-iam-role/"$course"/g /home/training/config/get_training_materials.sh 	
	ssh $nocheck training@gateway sed -i s/replace-materialsFileName/"$materialsFileName"/g /home/training/config/get_training_materials.sh 
	ssh $nocheck training@gateway sed -i s/replace-lowercase-course/"$lowercaseCourse"/g /home/training/config/get_training_materials.sh 
	ssh $nocheck training@gateway sed -i s/replace-courses-bucket/"$coursesBucket"/g /home/training/config/get_training_materials.sh 
	if [[ "$runSetup" == "no" ]]; then
		ssh $nocheck training@gateway sed -i '/setup.sh/d' /home/training/config/get_training_materials.sh 
	fi
}

config_course(){	
	echo "================================================="
	echo "Course-Specific Setup "
	echo "================================================="
	#get_training_materials both downloads the files, and runs the course-specific setup.sh
	if [[ "$course" != "None" ]]; then
		ssh -t $nocheck training@gateway mkdir -p /home/training/training_materials
		ssh -t $nocheck training@gateway 'cd /home/training/config ; exec ./update-s3-creds.sh'
		ssh -t $nocheck training@gateway 'cd /home/training/config ; exec ./get_training_materials.sh'
	else
		echo ""
		echo "You chose none as the course type, so no course-specific setup was done."
	fi
}

complete() {
	echo
	echo "Finished running create-cluster.sh at $(date '+%Y-%m-%d %T')"
	echo
}

#logic starts here
set_access
verify_host
verify_cmserver
check_if_existing_clusters
get_metadata
get_cluster_name
get_course_name
rds_lookups1
get_top_level_domain
cdsw_update_scripts
rds_lookups2
display_settings
create_instances
verify_cdsw_instances
config_networking
start_cmagents
verify_cmserver
#config_all_hosts
cdsw_configs
apply_cm_template
call_cm_api
if [[ "$checkForMultiCustom" != "" ]]; then
	custom_course
else
	config_S3_access
	config_course
fi
complete
