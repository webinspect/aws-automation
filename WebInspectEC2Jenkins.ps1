#######JENKINS POST BUILD SCRIPT STARTS HERE######
#globals
$wiScanSetting = ""
$wiLicenseToken = "guid"

$sscApplication = ""
$sscApplicationVersion = ""

$sscURL = "http://host:port/ssc"
$sscAuthToken = "guid"
$fortifyclient = "C:\Program Files\fortifyclient\bin\fortifyclient.bat"

$awsRegion=""

Try{

  Set-DefaultAWSRegion -Region ${awsRegion}

######DEPLOY WEBINSPECT#######
	#create a new EC2 instance
	#ami-5f1f8548 is a Windows Server 2012 R2 with SQL Express 2014, recommend to use at least m4.large or m4.xlarge
	$ami = "ami-5f1f8548"
	$ec2Policy = "EC2"
	$ec2InstanceType = "m4.large"
	
	
	Write-Host "Creating EC2 instance..."
	$ec2Instance = New-EC2Instance -ImageId $ami -MinCount 1 -MaxCount 1 -KeyName demokey -SecurityGroups default -InstanceType $ec2InstanceType -InstanceProfile_Name $ec2Policy
	$reservation = New-Object 'collections.generic.list[string]'
	$reservation.add(${ec2Instance}.ReservationId)
	$filter_reservation = New-Object Amazon.EC2.Model.Filter -Property @{Name = "reservation-id"; Values = $reservation}
	Write-Host "EC2 instance reserved, reservation ID: $reservation."
	
	
	Write-Host "Waiting for the EC2 instance to be in running state..."
	while((Get-EC2Instance -Filter $filter_reservation).Instances[0].State.Name -ne "running"){ 
		Start-Sleep -s 5 #poll status every 5 seconds
	}
	$instanceId = (Get-EC2Instance -Filter $filter_reservation).Instances[0].InstanceId
	Write-Host "EC2 instance is running, instance ID: $instanceId."

	#wait for the OS to be ready to receive commands
	Write-Host "Waiting for the OS to be ready to receive commands..."
	while((Get-EC2InstanceStatus $instanceId).Status.Status -ne "ok"){ 
		Start-Sleep -s 5 #poll status every 5 seconds
	}
	Write-Host "OS is ready."
	
	
	Write-Host "Installing .Net 4.6.1..."
	$installDotNet=Send-SSMCommand -InstanceId @($instanceId) -DocumentName AWS-RunPowerShellScript -Comment 'Install .Net 4.6.1' -Parameter @{'commands'=`
		@('$Url = "https://download.microsoft.com/download/E/4/1/E4173890-A24A-4936-9FC9-AF930FE3FA40/NDP461-KB3102436-x86-x64-AllOS-ENU.exe"',
		  '$Dest = "net461.exe"',
		  '$Params = "/q"',
		  '$client = new-object System.Net.WebClient',
		  '$client.DownloadFile($Url,$Dest)',
		  'Invoke-Expression ("cmd.exe /C $Dest $Params")')
	}
	$installDotNet = (Get-SSMCommandInvocation -CommandId $installWICommand.CommandId -Details $true).Status
	while($installDotNet -eq "Pending" -Or $installDotNet -eq "InProgress"){ 
		Start-Sleep -s 5 #poll status every 5 seconds
		$installDotNet = (Get-SSMCommandInvocation -CommandId $installWICommand.CommandId -Details $true).Status
	}
	Write-Host ".Net 4.6.1 installed."


	Write-Host "Installing WebInspect..."
	$installWICommand=Send-SSMCommand -InstanceId @($instanceId) -DocumentName AWS-RunPowerShellScript -Comment 'Install WebInspect' -Parameter @{'commands'=`
		@('Read-S3Object -BucketName webinspect/16.20 -Key WebInspect64.msi -File WebInspect64.msi',
		  'Start-Process msiexec "/i WebInspect64.msi /qn" -Wait',
		  'Start-Sleep -s 8',
		  'pushd "C:\Program Files\HP\HP WebInspect\"',
		  '.\WIConfig.exe /DisableSmartupdateOnStartup /DisableTelemetry',
		  '.\WIConfig.exe -RCServerPort 80',
		  $ExecutionContext.InvokeCommand.ExpandString('.\LicenseUtility.exe -p WebInspect -silent -y -token ${wiLicenseToken}'),
		  'Start-Sleep -s 8',
		  '.\WIConfig.exe -SqlConnString "Server=.; Database=WebInspect;Integrated Security=True;" /CreateDatabase',
                  'Start-Sleep -s 8',
		  '.\WIConfig.exe -SqlConnString "Server=.; Database=WebInspect;Integrated Security=True;" /CreateDatabase',
		  'start ASCMonitor.exe',
		  'netsh advfirewall firewall add rule name="WebInspect API" dir=in action=allow protocol=TCP localport=80',
		  'Read-S3Object -BucketName webinspect/settings -Key SharedSettings.config -File "C:\ProgramData\HP\HP WebInspect\SharedSettings.config"',
		  'net start "WebInspect API"')
	}
	$installCommandStatus = (Get-SSMCommandInvocation -CommandId $installWICommand.CommandId -Details $true).Status
	while($installCommandStatus -eq "Pending" -Or $installCommandStatus -eq "InProgress"){ 
		Start-Sleep -s 5 #poll status every 5 seconds
		$installCommandStatus = (Get-SSMCommandInvocation -CommandId $installWICommand.CommandId -Details $true).Status
	}
	Write-Host "WebInspect installed."

	
	Write-Host "Copying WebInspect Settings file ${wiScanSetting}..."
	$copyWISettingsCommand=Send-SSMCommand -InstanceId @($instanceId) -DocumentName AWS-RunPowerShellScript -Comment 'Copy WebInspect Scan Settings' -Parameter @{'commands'=`
		@($ExecutionContext.InvokeCommand.ExpandString('Read-S3Object -BucketName webinspect/settings -Key ${wiScanSetting} -File "C:\ProgramData\HP\HP WebInspect\Settings\${wiScanSetting}"'))
	}
	$copyWISettingsCommandStatus = (Get-SSMCommandInvocation -CommandId $copyWISettingsCommand.CommandId -Details $true).Status
	while($copyWISettingsCommandStatus -eq "Pending" -Or $copyWISettingsCommandStatus -eq "InProgress"){ 
		Start-Sleep -s 5 #poll status every 5 seconds
		$copyWISettingsCommandStatus = (Get-SSMCommandInvocation -CommandId $copyWISettingsCommand.CommandId -Details $true).Status
	}
	Write-Host "WebInspect settings ready."

	Write-Host "Instance is ready to scan."
	
#######RUN SCAN######### 
	$ec2PublicIP = (Get-EC2Instance -InstanceId $instanceId).Instances.PublicIpAddress;
	$wiAPI = "http://${ec2PublicIP}:80/webinspect/scanner"

	#start new scan
	Write-Host "Starting scan with settings ${wiScanSetting}..."
	$scanID = (Invoke-RestMethod -timeout 300000 -Method Post -Body "settingsName=${wiScanSetting}" -Uri ${wiAPI}).scanID
	Write-Host "Scan with ID ${scanID} is running."
	
	#wait until scan completes
	Write-Host "Waiting until scan has completed..."
	$getCurrentStatus = "${wiAPI}/${scanID}?action=getCurrentStatus"
	while(($scanStatus = (Invoke-RestMethod -timeout 300000 -Method Get -Uri ${getCurrentStatus}).ScanStatus) -eq "Running"){ 
		Start-Sleep -s 5 #poll scan status every 5 seconds
	}
	Write-Host "Scan status is ${scanStatus}."

	#download FPR from WebInspect
	$fprLocalFile = "${env:TEMP}\${env:BUILD_TAG}.fpr"
	$fprRemoteFile = "${wiAPI}/${scanID}.fpr"
	Write-Host "Downloading FPR from WebInspect to ${fprLocalFile}..."
	$(New-Object System.Net.WebClient).DownloadFile(${fprRemoteFile},${fprLocalFile})
	Write-Host "download complete."

	Write-Host "Uploading FPR ${fprLocalFile} to SSC Application ${sscApplication}, Version ${sscApplicationVersion}..."
	& $fortifyclient uploadFPR -url ${sscURL} -f ${fprLocalFile} -application ${sscApplication} -applicationVersion ${sscApplicationVersion} -authtoken ${sscAuthToken}
	Write-Host "upload complete."
	Remove-Item -Force ${fprLocalFile}
	
	#deactivate license
	Write-Host "Releasing WebInspect license..."
	$deactivateWILicenseCommand=Send-SSMCommand -InstanceId @($instanceId) -DocumentName AWS-RunPowerShellScript -Comment 'Release WebInspect License' -Parameter @{'commands'=`
		@('pushd "C:\Program Files\HP\HP WebInspect\"',
		  '.\LicenseUtility.exe -p WebInspect -deactivate -silent -y')
	}
	$deactivateWILicenseCommandStatus = (Get-SSMCommandInvocation -CommandId $deactivateWILicenseCommand.CommandId -Details $true).Status
	while($deactivateWILicenseCommandStatus -eq "Pending" -Or $deactivateWILicenseCommandStatus -eq "InProgress"){ 
		Start-Sleep -s 5 #poll status every 5 seconds
		$deactivateWILicenseCommandStatus = (Get-SSMCommandInvocation -CommandId $deactivateWILicenseCommand.CommandId -Details $true).Status
	}
	Write-Host "WebInspect license released."
	
	#terminate EC2 instance
	Remove-EC2Instance -InstanceId $instanceId -Force
	Write-Host "EC2 Instance terminated."
	
	exit 0
}
Catch {
	Write-Host $LastExitCode
	Write-Host $error
	exit 1
}
