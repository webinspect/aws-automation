# aws-automation

## WebInspectEC2Jenkins
The WebInspectEC2Jenkins.ps1 script is designed to be run in Jenkins via the PowerShell plugin. However, it can be easily modified to run as a standalone script or integrated into other tools.

### Prerequisites
* Jenkins +PowerShell plugin (https://jenkins.io/)
* AWS Tools for Windows PowerShell (https://aws.amazon.com/powershell/)

### Setup AWS
* Install AWS Tools for Windows PowerShell on the Jenkins machine
* Upload WebInspect installer to S3 (the script assumes the installer is named WebInspect64.msi and is installed in a bucket named webinspect/16.20)
* Upload WebInspect scan settings to S3 (the script assumes settings are installed in a bucket named webinspect/settings)
* Create an IAM user and generate an access key and secret.
* At a minimum, grant the IAM user rights to create and terminate EC2 instances, call SSM and read S3.
* Decide on base instance
    * I recommend and have tested with ami-5f1f8548, which is a Windows Server 2012 R2 with SQL Express 2014.
    * I also recommend to use at least m4.large or m4.xlarge sized instances.

### Setup Remote SSM Access
This section only needs to be performed once per IAM access key.
* This will associate a policy that allows that access key to call SSM commands (https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/managed-instances.html#service-role).
* You can find an example of SSMService-Trust.json in this repository.
* Run this script from any PowerShell console that has Internet access, it does not have to be the Jenkins machine.
~~~~
$awsAccessKey='accessKey'
$awsSecretKey='secretKey'
Set-AWSCredentials -AccessKey ${awsAccessKey} -SecretKey ${awsSecretKey} -StoreAs default
New-IAMRole -RoleName SSMServiceRole -AssumeRolePolicyDocument (Get-Content -raw SSMService-Trust.json)
Register-IAMRolePolicy -RoleName SSMServiceRole -PolicyArn 'arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM'
~~~~

### Setup SSC
* Make sure the fortifyclient tool is installed on the Jenkins machine (the script assumes it is located at C:\Program Files\fortifyclient)
* Create an SSC auth token:
~~~~
fortifyclient.bat token -gettoken AnalysisUploadToken -url http://127.0.0.1:8180/ssc -user admin
~~~~

### Setup Jenkins
* Install Jenkins Powershell Plugin.
* Create a Post Build event using the PowerShell plugin.
* Paste the WebInspectEC2Jenkins.ps1 script.
* Configure all of the parameters at the top of the script.
