#
#	List / Delete / Archive / Enable or Disable monitoring of
#					certificates in Windows certificate stores
#	use in SCOM task workflows
#
#		P/Invoke on cert32.dll was required as .NET does not currently
#		feature an object for advanced certificate stores (e.g. WinNT service based).
#
#		System requirements: Powershell >= 2.0 / .NET >= 2.0
#
#		Parameters
#			$computerName		
#			$storename			e.g. My
#			$storeProvider		SystemRegistry | System | File | LDAP
#			$storeType			LocalMachine | CurrentUser | Services | Users
#			$revocationFlag		EntireChain | ExcludeRoot | EndCertificateOnly
#			$revocationMode		Online | Offline | NoCheck
#			$verificationFlags  ...
#			$operation			DELETE|ARCHIVE|LIST|ENABLE|DISABLE|REDISCOVER
#			$verify				false | true (build chain to check if certs are valid
#			$searchArchived		false | true (to list archived certificates)
#			$tumbprint			certificate thumbprint (key property)
#			$scomTask			ID of task calling this script
#
# Version 1.0 - 04. November 2014 - initial            - Raphael Burri - raburri@bluewin.ch
# Version 2.0 - 19. Februar 2014 - added verification - Raphael Burri - raburri@bluewin.ch
#									and verbose chain status output
# Version 2.1 - 22. May 2015	- events with parameters to allow triggering rules
# Version 4.0 - 06. Sep 2018	- update store opening helper

#region parameters
param([string]$computerName = "localhost",
[string]$storeName = "My",
	[string]$storeProvider = "SystemRegistry",
	[string]$storeType = "LocalMachine",
	[string]$revocationFlag = "EntireChain", 
	[string]$revocationMode = "Offline", 
	[string]$verificationFlags = "IgnoreCertificateAuthorityRevocationUnknown,IgnoreEndRevocationUnknown", 
	[string]$operation = "List",
	#[string]$disableKey = "_disabled",
	[string]$disableKey = "_DoNotMonitor",
	[string]$verify = "true", 
	[string]$searchArchived = "false",
	[string]$wideOutput = "false",
	[string]$thumbprint = "",
	[string]$scomTask = "")
#endregion


#region just examples and placeholders for debug
#storeName: fullpath or just name. E.g.: "My" / c:\SOMEHWRE\store.bin / "WinNTServiceName\MY" etc...
#storeProvider: System (a summary map) / SystemRegistry (really is in registry) / File / LDAP
#storeType: LocalMachine / CurrentUser / Services / Users

#$storeName = "My"
#$debugParam = "true"
#$storeName = "aspnet_state\My"
#$storeProvider = "System"
#$storeProvider = "LDAP"
#endregion

#region variables and constants
# get script name
# SCOM agent calls them dynamically, assigning random names
#$scriptName = $MyInvocation.MyCommand.Name
$scriptName = "Certificate_Handling_Script_V4.ps1"
$userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$CERTVALID   =  "IsVerified"


#constants for crypt32.dll methods
[int]$CERT_STORE_PROV_MEMORY = 0x02
[int]$CERT_STORE_PROV_FILE = 0x03
[int]$CERT_STORE_PROV_REG = 0x04
[int]$CERT_STORE_PROV_PKCS7 = 0x05
[int]$CERT_STORE_PROV_SERIALIZED = 0x06
[int]$CERT_STORE_PROV_FILENAME = 0x08
[int]$CERT_STORE_PROV_SYSTEM = 0x0A
[int]$CERT_STORE_PROV_COLLECTION = 0x0B
[int]$CERT_STORE_PROV_SYSTEM_REGISTRY = 0x0D
[int]$CERT_STORE_PROV_SMART_CARD = 0x0F
[int]$CERT_STORE_PROV_LDAP = 0x10


[int]$CERT_STORE_ENUM_ARCHIVED_FLAG = 0x00000200
[int]$CERT_STORE_OPEN_EXISTING_FLAG = 0x00004000
[int]$CERT_STORE_READONLY_FLAG = 0x00008000

[int]$CERT_SYSTEM_STORE_CURRENT_USER =  0x00010000
[int]$CERT_SYSTEM_STORE_LOCAL_MACHINE = 0x00020000
[int]$CERT_SYSTEM_STORE_CURRENT_SERVICE = 0x00040000
[int]$CERT_SYSTEM_STORE_SERVICES = 	 0x00050000
[int]$CERT_SYSTEM_STORE_USERS = 0x00060000
[int]$CERT_SYSTEM_STORE_CURRENT_USER_GROUP_POLICY = 0x00070000
[int]$CERT_SYSTEM_STORE_LOCAL_MACHINE_GROUP_POLICY = 0x00080000
[int]$CERT_SYSTEM_STORE_LOCAL_MACHINE_ENTERPRISE = 0x00090000

#see on input parameters - default to LocalSystem store My (personal computer store), SystemRegistry provider (registry) and LocalSystem storetype
if ($storeName -eq "") { $storeName = "My"}
# system reflect a map (includes Third-Party, Group, Enterprise etc.)
if ($storeProvider -eq "System") { $storeProv = $CERT_STORE_PROV_SYSTEM}
# systemregistry only returns the certificates physically present in the local registry
elseif ($storeProvider -eq "SystemRegistry") { $storeProv = $CERT_STORE_PROV_SYSTEM_REGISTRY}
elseif ($storeProvider -eq "File") { $storeProv = $CERT_STORE_PROV_FILE}
elseif ($storeProvider -eq "LDAP") { $storeProv = $CERT_STORE_PROV_LDAP}
else {$storeProv = $CERT_STORE_PROV_SYSTEM_REGISTRY}
if ($storeType -eq "LocalSystem") { $storeTp = $CERT_SYSTEM_STORE_LOCAL_MACHINE}
elseif ($storeType -eq "CurrentUser") { $storeTp = $CERT_SYSTEM_STORE_CURRENT_USER}
elseif ($storeType -eq "Services") { $storeTp = $CERT_SYSTEM_STORE_SERVICES}
elseif ($storeType -eq "Users") { $storeTp = $CERT_SYSTEM_STORE_USERS}
else { $storeTp = $CERT_SYSTEM_STORE_LOCAL_MACHINE}

#set open_existing and readwrite (default)
$storeTp = $storeTp + $CERT_STORE_OPEN_EXISTING_FLAG
if ($searchArchived -eq "true") { $storeTp = $storeTp + $CERT_STORE_ENUM_ARCHIVED_FLAG }


#PoSh 2.0 was shipped with 2008R2/Win7. In order to have as little dependency on later updates
#     as possible this script only uses 2.0 cmdlets
$minimalPSVersion = "2.0"

#lookup for certificates snap-in friendly names (in english only)
$storeNameTable = @{"AuthRoot" = "Third-Party Root Certification Authorities";
	"CA" = "Intermediate Certification Authorities";
	"Disallowed" = "Untrusted Certificates";
	"My" = "Personal";
	"REQUEST" = "Certificate Enrollment Requests";
	"Root" = "Trusted Root Certification Authorities";
	"SmartCardRoot" = "Smart Card Trusted Roots";
	"Trust" = "Enterprise Trust";
	"TrustedDevices" =  "Trusted Devices";
	"TrustedPeople" = "Trusted People";
	"TrustedPublisher" = "Trusted Publisher";
	"WebHosting" = "Web Hosting"}
	
#initialize hash tables
$certificateObjects = @()
#endregion

#region C# Signature
# C# module imports and types where-type variable
# as not all store access options are implemented in System.Security.Cryptography.X509Certificates
 $x509HelperSignature = @"
 using System;
 using System.Runtime.InteropServices;
 using System.Security;
 using System.Security.Cryptography;
 using System.Security.Cryptography.X509Certificates;
  
 namespace SystemCenterCentral
 {
     namespace Utilities
     {
         namespace Certificates
         {
                 public class HelperTasks {
                     [DllImport("crypt32.dll", EntryPoint="CertOpenStore", CharSet=CharSet.Auto, SetLastError=true)]
                     public static extern IntPtr CertOpenStoreStringPara(
                                     int storeProvider,
                                     int encodingType,
                                     IntPtr hcryptProv,
                                     int flags,
                                     String pvPara);
                                    
                     [DllImport("crypt32.dll", EntryPoint="CertCloseStore", CharSet=CharSet.Auto, SetLastError=true)]
                     [return : MarshalAs(UnmanagedType.Bool)]
                     public static extern bool CertCloseStore(
                                     IntPtr storeProvider,
                                     int flags);
                }

         }
     }
 }
"@
#endregion

# Get access to the scripting API
$scomAPI = new-object -comObject "MOM.ScriptAPI"

# check if Powershell >= 2.0 is running
if( ($PSVersionTable.PSCompatibleVersions) -contains $minimalPSVersion)
	{
	#Write-Host Powershell installed: ( $PSVersionTable.PSVersion.ToString() )
	#Write-Host      It is compatible with version $minimalPSVersion required by this script
	}
else
	{
	#Write-Host Powershell installed: $PSVersionTable.PSVersion.ToString() `t`t`t`t`t`t`t`t -BackgroundColor red 
	#Write-Host `tIt is not compatible with version $minimalPSVersion required by this script `t -BackgroundColor red
	exit
	}


#region check if the parameters are valid
$X509ParamEx = ""
$scriptParamValid = $false
if (($operation -imatch "^(ENABLE|DISABLE|DELETE|ARCHIVE|REDISCOVER)$") -and ($thumbprint -imatch ".+")) { $scriptParamValid = $true }
if (($operation -imatch "^LIST$") -and ($verify -imatch "false")) { $scriptParamValid = $true }
#if verification is rewquired, check on flags as well
if (($operation -imatch "^LIST$") -and ($verify -imatch "true")) {
	$scriptParamValid = $true
	try {[System.Security.Cryptography.X509Certificates.X509RevocationFlag]$X509RevocationFlag = $revocationFlag}
	catch {Write-Warning $_
		$scriptParamValid = $false
		$X509ParamEx += [string]$_ + "
"
		# stick to default
		[System.Security.Cryptography.X509Certificates.X509RevocationFlag]$X509RevocationFlag = "EntireChain"
		}
	try {[System.Security.Cryptography.X509Certificates.X509RevocationMode]$X509RevocationMode = $revocationMode}
	catch {Write-Warning $_ 
		$scriptParamValid = $false
		$X509ParamEx += [string]$_ + "
"
		# stick to default
		[System.Security.Cryptography.X509Certificates.X509RevocationMode]$X509RevocationMode = "Online"
		}
	try {[System.Security.Cryptography.X509Certificates.X509VerificationFlags]$X509VerificationFlags = $verificationFlags}
	catch {Write-Warning $_
		$scriptParamValid = $false
		$X509ParamEx += [string]$_ + "
"
		#stick to default
		[System.Security.Cryptography.X509Certificates.X509VerificationFlags]$X509VerificationFlags = "IgnoreCertificateAuthorityRevocationUnknown,IgnoreEndRevocationUnknown"
		}
	}

if ($scriptParamValid -eq $false)
	{
	"Script starting with default certificate handling parameters (LIST) as the overridden ones were invalid:

Parameters:
-----------
storeName: " + $storeName + "
storeProvider: " + $storeProvider + "
storeType: " + $storeType + " 

Possibly Invalid Parameter:
----------------
RevocationFlag: " + $revocationFlag + "
RevocationMode: " + $revocationMode + "
VerificationFlags: " + $verificationFlags + "
Operation: " + $operation + "
Thumbprint: " + $thumbprint + "

Exception Detail:
----------------
" + $X509ParamEx | Write-Output	
	}
#endregion

function main
	{

    # loading crypt32.dll type to [SystemCenterCentral.Utilities.Certificates.HelperTasks]
	# NOTE: no exception occurs if type was already loaded. Runtime will then just use the previous one
	try
       {Add-Type -TypeDefinition $x509HelperSignature}
	catch 
		{
		#throw "Unable to load [SystemCenterCentral.Utilities.Certificates.HelperTasks] namespace with crypt32.dll methods"
		$scomAPI.LogScriptEvent($scriptName, 129, 2, "Unable to load [SystemCenterCentral.Utilities.Certificates.HelperTasks] namespace with crypt32.dll methods. Retrying on the next script run.")
		#exit
	}
	#ready to rumble
	
	#get certificate store
	$certStorePt = [SystemCenterCentral.Utilities.Certificates.HelperTasks]::CertOpenStoreStringPara($storeProv, 0, 0, $storeTp, $storeName)
	if ($certStorePt -ne 0)
	{
		# first see about certificates
		#take it from store pointer to full .NET as certificates are exposed there and easier to handle.
		#    this works perfectly for File, LDAP or WinNT service stores.
		$certStore = [System.Security.Cryptography.X509Certificates.X509Store]$certStorePt
		$global:certStore = $certStore
		
		# pre-release MP versions used _disable - so make sure that is removed as well
		if ($operation -eq 'ENABLE') { Set-X509CertificateEnabled -certStore $certStore -certTumbprint $thumbprint -disableKey ('(' + $disableKey + '|_disabled)') }
		if ($operation -eq 'DISABLE') { Set-X509CertificateDisabled -certStore $certStore -certTumbprint $thumbprint -disableKey $disableKey }
		if ($operation -eq 'DELETE') { Remove-X509Certificate -certStore $certStore -certTumbprint $thumbprint }
		if ($operation -eq 'ARCHIVE') { SET-X509CertificateArchived -certStore $certStore -certTumbprint $thumbprint }
		if ($operation -eq 'LIST') { GET-X509Certificate -certStore $certStore -certTumbprint $thumbprint -wideOutput $wideOutput -verify $verify }
		if ($operation -eq 'REDISCOVER') { 
			Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 121 -EventSeverity 'Information' -EventDescription ("
Task to ask for re-discovery was run.

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
		
			Write-Output ("Asked for re-discovery of the certificate store by writing local event.")
		}
		
		# close store
		$closeStore = [SystemCenterCentral.Utilities.Certificates.HelperTasks]::CertCloseStore($certStorePt, 0)
		}
	else
		{
		$scomAPI.LogScriptEvent($scriptName, 120, 2, ("Failed to open certificate store.`n`nstoreName: {0}`nstoreProvider: {1}`nstoreType: {2}" -f $storeName,$storeProvider,$storeType)) 
		}
		
	#write summary event
	}

#removes "disable" flag from certificate's friendly name
function Set-X509CertificateEnabled	{
	param([System.Security.Cryptography.X509Certificates.X509Store]$certStore = $null,
		[string]$certTumbprint = '',
		[string]$disableKey = '_(disabled|DoNotMonitor)')
		
	$isEnabled = $true
	$cert = $certStore.Certificates | where {$_.Thumbprint -eq $certTumbprint}
	if ($cert) {
		$certFriendlyName = [string]$cert.get_FriendlyName()
		Write-Output ("Certificate with thumbprint $certTumbprint selected...")
		if ($certFriendlyName -imatch ( '(?<friendlyNameCore>.*)' + $disableKey + '$')) {
			#certificate is currently disabled
			try { $cert.set_FriendlyName([string]($matches.friendlyNameCore)) }
			catch { Write-Output ("Failed to remove '" + $disableKey + "' from certificate friendly name.") }
			}
		Write-Output ("Friendly Name set to: " + [string]$cert.get_FriendlyName())
		Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 122 -EventSeverity 'Information' -EventDescription ("
Friendly name tag of certificate was removed via SCOM task '" + $scomTask + "' by user " + $userName + ". Monitoring will resume following the next discovery cycle.

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
		}
	else { Write-Output ("Certificate with thumbprint $certTumbprint does not exist.") }
}
	
#adds "disable" flag to certificate's friendly name
function Set-X509CertificateDisabled	{
	param([System.Security.Cryptography.X509Certificates.X509Store]$certStore = $null,
		[string]$certTumbprint = '',
		#[string]$disableKey = '_disabled'
		[string]$disableKey = '_DoNotMonitor')
		
	$isEnabled = $true
	$cert = $certStore.Certificates | where {$_.Thumbprint -eq $certTumbprint}
	if ($cert) {
		$certFriendlyName = [string]$cert.get_FriendlyName()
		Write-Output ("Certificate with thumbprint $certTumbprint selected...")
		if ($certFriendlyName -inotmatch ($disableKey + '$')) {
			#certificate is currently enabled
			try { $cert.set_FriendlyName(($certFriendlyName + $disableKey)) }
			catch { Write-Output ("Failed to append '" + $disableKey + "' to certificate friendly name.") }
			}
		Write-Output ("Friendly Name set to: " + [string]$cert.get_FriendlyName())
		Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 123 -EventSeverity 'Information' -EventDescription ("
Friendly name tag of certificate was added via SCOM task '" + $scomTask + "' by user " + $userName + ". Monitoring will stop following the next discovery cycle.

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
		}
	else { Write-Output ("Certificate with thumbprint $certTumbprint does not exist.") }
	}

function Remove-X509Certificate	{
	param([System.Security.Cryptography.X509Certificates.X509Store]$certStore = $null,
		[string]$certTumbprint = '')
		
	$cert = $certStore.Certificates | where {$_.Thumbprint -eq $certTumbprint}
	if ($cert) {
			if ($certStore.Remove($cert) -eq $null) { 
				Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 124 -EventSeverity 'Warning' -EventDescription ("
Certificate was DELETED via SCOM task '" + $scomTask + "' by user " + $userName + ".

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
			
				#SCOM Task Output
				Write-Output ("Certificate with thumbprint $certTumbprint was DELETED succesfully.")
				}
			else { 
				Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 125 -EventSeverity 'Warning' -EventDescription ("
Certificate could not be DELETED via SCOM task '" + $scomTask + "' by user " + $userName + ".

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName

				Write-Output ("Failed to delete certificate with thumbprint $certTumbprint")
			}
		
		}
	else {
		Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 126 -EventSeverity 'Warning' -EventDescription ("
Certificate could not be deleted by " + $userName + ".

No certificate with thumbprint " + $certTumbprint + " was found in the store.

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
	
				#SCOM Task Output
				Write-Output ("Certificate with thumbprint $certTumbprint could not be deleted as it does not exist.")
		}
	
	}
	
function Set-X509CertificateArchived	{
	param([System.Security.Cryptography.X509Certificates.X509Store]$certStore = $null,
		[string]$certTumbprint = '')
		
	$cert = $certStore.Certificates | where {$_.Thumbprint -eq $certTumbprint}
	if ($cert) {
		try{ $cert.set_Archived($true) }
		catch { 
			$certArchivalFailed = $true
			Write-Output ("Setting ARCHIVED flag on certificate with thumbprint $certThumbprint failed") 
			}
		if ($certArchivalFailed -ne $true) { 
			Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 127 -EventSeverity 'Information' -EventDescription ("
Certificate was ARCHIVED via SCOM task '" + $scomTask + "' by user " + $userName + ".

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
		
				#SCOM Task Output
				Write-Output ("Certificate with thumbprint $certTumbprint was ARCHIVED succesfully.")
				}
		}
	else {
		Write-EventLogEntry -EventLogName 'Operations Manager' -EventSourceName 'Health Service Script' -EventId 128 -EventSeverity 'Warning' -EventDescription ("
Certificate could not be archived by " + $userName + ".

No certificate with thumbprint " + $certTumbprint + " was found in the store.

Subject: " + $cert.Subject + "
Issuer: " + $cert.Issuer + "
Thumbprint: " + $cert.Thumbprint + "

Computer: %3
Store Name: %4
Store Provider: " + $storeProvider + "
Store Type: " + $storeType) -EventParameter1 $ScriptName -EventParameter2 $computerName -EventParameter3 $storeName
		
				#SCOM Task Output
				Write-Output ("Certificate with thumbprint $certTumbprint could not be archived as it does not exist in the store.")
		}
	
	}
	
function Get-X509Certificate {
	param([System.Security.Cryptography.X509Certificates.X509Store]$certStore = $null,
		[string]$certTumbprint = '',
		[string]$wideOutput = 'false',
		[string]$verify = 'true')
		
		$certValidated = @()
		
		if ($certTumbprint.length -eq 0) { $certTumbprint = '.' }
		Write-Output ("Certificates in " + $storeType + " store " + $storeName + "`n`t(user context " + $userName + "): matching thumbprint '" + $certTumbprint + "'`n")
		
		$certStore.Certificates | where {$_.Thumbprint -imatch $certTumbprint } | % {
			$validated = [string]"n/a"
			$certIsValidated = $true
			$chainIsValidated = $true
			$certVerboseStatusString = $null
			if ($verify -imatch "true") {
				$certValidObj = Validate-X509Certificate2 -X509Certificate2 $_ -X509RevocationFlag $X509RevocationFlag -X509RevocationMode $X509RevocationMode -X509VerificationFlags $X509VerificationFlags
				$validated = $certValidObj[0]
				#build verbose status string for screen output
				$validationStatusMatch = '^(RevocationStatusUnknown:|OfflineRevocation:)'
				if ( $certValidObj[1] -ne $null) {
					#get certificate issue from [2]
					$certVerboseStatusString = [string]($certValidObj[2] | where  {$_ -notmatch $validationStatusMatch} | % {(($_).trim() + "`n")})
					if ($certVerboseStatusString.length -le 0) { $certVerboseStatusString = $CERTVALID + "`n" }
					else {$certIsValidated = $false}
					$certVerboseStatusString = "--- Certificate Status ---`n" + $certVerboseStatusString
					#get chain status from [3]
					if ($certValidObj[3] -ne $null ) {
						$certVerboseStatusString = $certVerboseStatusString + "`n--- Chain Status Overview ---`n"
						$certValidObj[3]| % {
							$certVerboseStatusStringChain = ($_.chainSummary | where  {$_ -notmatch $validationStatusMatch})
							if ($certVerboseStatusStringChain.length -le 0) { $certVerboseStatusStringChain = $CERTVALID + "`n" }
							else {$chainIsValidated = $false}
							$certVerboseStatusString = $certVerboseStatusString + ("Level " + $_.ChainLevel + ": " + $_.ChainSubject + "`n" + $certVerboseStatusStringChain + "`n") 
						}
					}
				}
				if (($certIsValidated -eq $true) -and ($chainIsValidated -eq $true)) {$validated = $true}
			}
			$certValidatedObj = New-Object psobject
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name Subject -Value $_.Subject
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name Issuer -Value $_.Issuer
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name Thumbprint -Value $_.Thumbprint
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name Archived -Value $_.Archived
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name NotAfter -Value $_.NotAfter
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name DaysValid -Value (($_.NotAfter.ToUniversalTime() - (Get-Date).ToUniversalTime()).Days)
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name IsValid -Value $validated
			$certValidatedObj | Add-Member -MemberType NoteProperty -Name ValidationDetail -Value $certVerboseStatusString
			$certValidated += $certValidatedObj
		}
		if ($verify -imatch "true")
			{
			Write-Output ([string]@($certValidated | where {$_.IsValid -eq $true}).Count + " Valid Certificate(s)")
			Write-Output "----------------------"
			if ($wideOutput -eq 'false') {
				#$certValidated | where {$_.IsValid -eq $true} | ft -wrap Subject,Issuer,NotAfter,DaysValid,Thumbprint | Write-Output
				$certValidated | where {$_.IsValid -eq $true} | Format-Table -Wrap `
					@{Name='Subject               '; Expression={$_.Subject}; Width=22},`
					@{Name='Issuer                '; Expression={$_.Issuer}; Width=22},`
					@{Name='NotAfter   '; Expression={$_.NotAfter}; Width=11},`
					@{Name='DaysValid'; Expression={$_.DaysValid}; Width=9},`
					@{Name='Thumbprint '; Expression={$_.Thumbprint}; Width=11} | Out-String 
			}			
			else
				{$certValidated | where {$_.IsValid -eq $true} | ft -AutoSize -wrap Subject,Issuer,NotAfter,DaysValid,Thumbprint | Out-String -width 2048 | Write-Output}
			Write-Output ([string]@($certValidated | where {$_.IsValid -eq $false}).Count + " Invalid Certificate(s)")
			Write-Output "----------------------"
			if ($wideOutput -eq 'false')
				{$certValidated | where {$_.IsValid -eq $false} | % {
					#$_ | ft -wrap Subject,Issuer,NotAfter,DaysValid,Thumbprint | Write-Output
					#$_ | ft -HideTableHeaders -Wrap ValidationDetail | Write-Output
					$_ | Format-Table -Wrap `
						@{Name='Subject               '; Expression={$_.Subject}; Width=22},`
						@{Name='Issuer                '; Expression={$_.Issuer}; Width=22},`
						@{Name='NotAfter   '; Expression={$_.NotAfter}; Width=11},`
						@{Name='DaysValid'; Expression={$_.DaysValid}; Width=9},`
						@{Name='Thumbprint '; Expression={$_.Thumbprint}; Width=11} | Out-String 
					$_ | Format-Table -HideTableHeaders -Wrap `
						@{Name='02'; Expression={'  '}; Width=2},`
						@{Name='ValidationDetail'; Expression={$_.ValidationDetail}; Width=77} | Out-String
					}
				}
			else
				{$certValidated | where {$_.IsValid -eq $false} | % {
					$_ | ft -AutoSize -wrap Subject,Issuer,NotAfter,DaysValid,Thumbprint | Out-String -width 2048 | Write-Output
					$_ | ft -AutoSize -HideTableHeaders -Wrap ValidationDetail | Out-String -width 2048 | Write-Output
					}
				}
			}
		else
			{
			Write-Output ([string]@($certValidated).Count + " Certificate(s)")
			Write-Output "----------------------"
			if ($wideOutput -eq 'false') {
				#$certValidated | ft -wrap Subject,Issuer,NotAfter,DaysValid,Thumbprint | Write-Output
				$certValidated | Format-Table -Wrap `
					@{Name='Subject               '; Expression={$_.Subject}; Width=22},`
					@{Name='Issuer                '; Expression={$_.Issuer}; Width=22},`
					@{Name='NotAfter   '; Expression={$_.NotAfter}; Width=11},`
					@{Name='DaysValid'; Expression={$_.DaysValid}; Width=9},`
					@{Name='Thumbprint '; Expression={$_.Thumbprint}; Width=11} | Out-String 
			}
			else
				{$certValidated | ft -AutoSize -wrap Subject,Issuer,NotAfter,DaysValid,Thumbprint | Out-String -width 2048 | Write-Output}
			}
		
}

function Validate-X509Certificate2
# using pure .NET for certificate validation
	{
	param($X509Certificate2, $X509RevocationFlag, $X509RevocationMode, $X509VerificationFlags)
		
	$X509Chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain

	#	EndCertificateOnly: Only the end certificate is checked for revocation.  
 	#	EntireChain:		The entire chain of certificates is checked for revocation.  
 	#	ExcludeRoot:		The entire chain, except the root certificate, is checked for revocation.  
	$X509Chain.ChainPolicy.RevocationFlag = $X509RevocationFlag
	
	#	NoCheck:	No revocation check is performed on the certificate.  
 	#	Offline:	A revocation check is made using a cached certificate revocation list (CRL).  
 	#	Online: 	A revocation check is made using an online certificate revocation list (CRL).  
	$X509Chain.ChainPolicy.RevocationMode = $X509RevocationMode
	
	#	AllFlags:										All flags pertaining to verification are included.  
 	#	AllowUnknownCertificateAuthority:				Ignore that the chain cannot be verified due to an unknown certificate authority (CA).  
 	#	IgnoreCertificateAuthorityRevocationUnknown:	Ignore that the certificate authority revocation is unknown when determining certificate verification.  
 	#	IgnoreCtlNotTimeValid:							Ignore that the certificate trust list (CTL) is not valid, for reasons such as the CTL has expired, when determining certificate verification.  
 	#	IgnoreCtlSignerRevocationUnknown:				Ignore that the certificate trust list (CTL) signer revocation is unknown when determining certificate verification.  
 	#	IgnoreEndRevocationUnknown:						Ignore that the end certificate (the user certificate) revocation is unknown when determining certificate verification.  
 	#	IgnoreInvalidBasicConstraints:					Ignore that the basic constraints are not valid when determining certificate verification.  
 	#	IgnoreInvalidName:								Ignore that the certificate has an invalid name when determining certificate verification.  
 	#	IgnoreInvalidPolicy:							Ignore that the certificate has invalid policy when determining certificate verification.  
 	#	IgnoreNotTimeNested:							Ignore that the CA (certificate authority) certificate and the issued certificate have validity periods that are not nested when verifying the certificate. For example, the CA cert can be valid from January 1 to December 1 and the issued certificate from January 2 to December 2, which would mean the validity periods are not nested.  
 	#	IgnoreNotTimeValid:								Ignore certificates in the chain that are not valid either because they have expired or they are not yet in effect when determining certificate validity.  
 	#	IgnoreRootRevocationUnknown:					Ignore that the root revocation is unknown when determining certificate verification.  
 	#	IgnoreWrongUsage:								Ignore that the certificate was not issued for the current use when determining certificate verification.  
 	#	NoFlag:											No flags pertaining to verification are included.  
	$X509Chain.ChainPolicy.VerificationFlags = $X509VerificationFlags
	
	#explicitly forcing verificationtime to NOW
	$X509Chain.ChainPolicy.VerificationTime = (Get-Date).ToUniversalTime()
	
	$statusSummaryChain = @()
	
	#Builds an X.509 chain using the policy specified
	#   true if the X.509 certificate is valid; otherwise, false
	if ($X509Chain.Build($X509Certificate2))
		{
		#Write-Host  -BackgroundColor green $X509Certificate2.Subject is valid
		$valid = $true
		$statusSummary = $null
		$statusSummaryCert = $null
		$statusSummaryChain = $null
		}
	else
		{
		$valid = $false
		#Write-Host  -BackgroundColor Yellow $X509Certificate2.Subject is not valid
		$statusSummary = $X509Chain.ChainStatus | %{
			if ($_.StatusInformation.ToString().Trim() -imatch '^unknown error\.') {($_.Status.ToString().Trim() + ":")}
			else {($_.Status.ToString().Trim() + ": " + $_.StatusInformation.ToString().Trim())}
			}
		if ($X509Chain.ChainElements.Count -gt 1) {
			#build verbose string with the chain level status
			$chainLevel = ($X509Chain.ChainElements.Count - 1)
			$X509Chain.ChainElements | % {
				#certificate's status
				if ($_.Certificate.Thumbprint -eq $X509Certificate2.Thumbprint) {
					if ($_.ChainElementStatus)	{
						$statusSummaryCert = $_.ChainElementStatus | %{
							if ($_.StatusInformation.ToString().Trim() -imatch '^unknown error\.') {($_.Status.ToString().Trim() + ":" + "`n")}
							else {($_.Status.ToString().Trim() + ": " + $_.StatusInformation.ToString().Trim() + "`n")}
							}
						#Write-Host -BackgroundColor yellow CERT: $statusSummaryCert
						}
					else { 
						$statusSummaryCert = $CERTVALID
						#Write-Host -BackgroundColor green CERT: $statusSummaryCert
						}
					}
				#chain element status
				else {
					$statusSummaryChainObj = New-Object psobject
					$statusSummaryChainObj | Add-Member -MemberType NoteProperty -Name chainLevel -Value $chainLevel
					$statusSummaryChainObj | Add-Member -MemberType NoteProperty -Name chainSubject -Value $_.Certificate.Subject
					if ($_.ChainElementStatus)	{
						$statusSummaryChainCert = $_.ChainElementStatus | %{
							if ($_.StatusInformation.ToString().Trim() -imatch '^unknown error\.') {($_.Status.ToString().Trim() + ":" +"`n")}
							else {($_.Status.ToString().Trim() + ": " + $_.StatusInformation.ToString().Trim() + "`n")}
							}
							#Write-Host -BackgroundColor yellow CHAIN: $statusSummaryChain
						}
					else {
						$statusSummaryChainCert = $CERTVALID
						#Write-Host -BackgroundColor green CHAIN: $statusSummaryChain
						}
					$statusSummaryChainObj | Add-Member -MemberType NoteProperty -Name chainSummary -Value $statusSummaryChainCert
				
					$statusSummaryChain += $statusSummaryChainObj
				
					}
				$chainLevel--	
				}
			}
		else {
			$statusSummaryCert = $statusSummary
			$statusSummaryChain = $null
			}
		}
	return $valid, $statusSummary, $statusSummaryCert, $statusSummaryChain
	}

Function Write-EventLogEntry
{
	param ([string]$EventLogName, [string]$EventSourceName, $EventId ,[string]$EventSeverity, [string]$EventDescription, [string]$EventParameter1, [string]$EventParameter2, [string]$EventParameter3) 
	# using .NET objects as they allow event parameters
	$newEvent = new-object System.Diagnostics.Eventinstance($EventId, 0, [system.diagnostics.eventlogentrytype]::[string]$EventSeverity) 
	[system.diagnostics.EventLog]::WriteEvent([string]$EventSourceName, $newEvent, $EventDescription, $EventParameter1, $EventParameter2, $EventParameter3)
}

#call main function
Main