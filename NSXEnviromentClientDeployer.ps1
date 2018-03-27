<#

    Marcus Hansen     - revision 1 - 7/21/17 - added function connectToNSXManager, main  <Removed function connectToNSXManager>
                        revision 2 - 7/24/17 - added login to main, and NSX error checking
                        revision 3 - 7/25/17 - added logical switch to up/down links for esg, datastore, and resource pool configuration
                        revision 4 - 7/28/17 - added logical switches for north/south (upstream/downstream) connections to the ESG interfaces
                        revision 5 - 8/2/17  - added DLR, and 3 internal interfaces and OSPF neighborship parameters
                        revision 6 - 8/6/17  - added additional error checking, and cleanup function in case of duplicates found within
                                               the exisiting NSX environment. added function for testing duplicate objects in NSX due to how
                                               much that code was being repeated in main() function


    Major Dependencies:
                        PowerCLI
                        PowerNSX
                        InfoBlox - IPAM <TODO>
                        ServiceNow Integration


    Script Use:         Automated NSX Deployment for Client-Onboarding 
#>

<# GLOBALS #>
<#===========================#>
$dataStoreName     = ""
$resourcePool      = "" <# Needs to be explicit Resource Pool, cluster top-level will not suffice #>
$tenant            = ""
$vcenterServer     = ""
$nsxManager        = ""


$nameSwitchArgs    = @()
$esgName           = " "
$dlrName           = " "
$nameOfDuplicate   = " "                
<#===========================#>


<# ENTRY POINT #>
<#===========================#>
main


<#
    function:     main
    purpose:      Our Script logic will go here
    returns:      void
    called from : Global

#>
function main
{
    try
    {
        Connect-VIServer  $(Read-Host 'Please enter the VMCenter IP address')   -ErrorAction Stop
        Connect-NsxServer $(Read-Host 'Please enter the NSXManager IP address') -ErrorAction Stop
    }
    catch
    {
        Write-Host "Failed to connect with vCenter/nsxManager"
        Exit
    }

    Write-Host "Script for Automation of NSX deployment"
    
    <# Get our Transport Zone #>
    $transportZone  = Read-Host "Enter Transport-Zone for logical switches connecting to ESG"

    <# Create our Switches for the ESG, and DLR #>
    $lsType         = "ESG Transit", "DLR Transit", "DLR Heartbeat", "DMZ", "App", "DB"
    for ($i = 0; $i -le 5; $i++)
    {
        <# Get the switch names #>
        $nameSwitchArgs = $nameSwitchArgs + $(Read-Host "Enter the names of the logical switches ($($lsType[$i]))")
        Write-Host "Polling exisiting Logical Switches from NSX environment for duplicate testing..."

        <# Test for duplicates #>
        foreach ($switch in Get-NsxLogicalSwitch) 
        { 
            <# if duplicate is found, cleanup, hard stop #>
            if ($(testNSXDuplicates $switch.Name $nameSwitchArgs[$i] "Error: Duplicate switch found in NSX"))
            {
                cleanup
                Exit
            }
        } 

        <# Create our switches #>
        try { New-NsxLogicalSwitch -Name $nameSwitchArgs[$i] -TransportZone $(Get-NsxTransportZone  $transportZone) -ErrorAction Stop }
        catch 
        {
            Write-Host "Error: Could not create logical switch $($nameSwitchArgs[$i]), verify transportZone, and try again"
            $nameSwitchArgs[$i] = " "
            cleanup
            Exit
        }
    }

    <# Get our parameters for the new ESG #>
    $esgName                    = Read-Host 'Enter the name of the edge'
    $esgHostname                = Read-Host 'Enter the hostname of the edge'
    
    $esgUplinkPrimaryAddress    = Read-Host "Enter primary address for edge uplink"
    $esgUplinkSecondaryAddress  = Read-Host "Enter secondary address for edge uplink"
    $uplDefaultSubnetBits       = Read-Host "Enter the number of subnet bits for edge uplink"

    $esgDLRPrimaryAddress       = Read-Host "Enter primary address for edge to dlr"
    $esgDLRSecondaryAddress     = Read-Host "Enter secondary address for edge to dlr"
    $dlrDefaultSubnetBits       = Read-Host "Enter the number of subnet bits for edge to dlr"
    
    <# TODO(InfoBlox integration for IPAM): procureIPRange(e.g. 24) #>

    <# Create the esg interfaces, one for the upstream connection, the other for the downstream to the dlr #>
    <# TODO: Interface with infoblocks API to validate IP address usage #>

    try
    {
        $edgeIntUp  = New-NsxEdgeinterfacespec -index 0 -Name "Uplink"      -type Uplink   -PrimaryAddress $esgUplinkPrimaryAddress -SecondaryAddress $esgUplinkSecondaryAddress -SubnetPrefixLength $uplDefaultSubnetBits -ConnectedTo $(Get-NsxLogicalSwitch -Name $nameSwitchArgs[0]) -ErrorAction Stop
        $edgeIntDlr = New-NsxEdgeInterfaceSpec -index 1 -Name "DLR-Transit" -type internal -PrimaryAddress $esgDLRPrimaryAddress    -SecondaryAddresses $esgDLRSecondaryAddress  -SubnetPrefixLength $dlrDefaultSubnetBits -ConnectedTo $(Get-NsxLogicalSwitch -Name $nameSwitchArgs[1]) -ErrorAction Stop
    }
    catch 
    {
        Write-Host "Error: Could not create EdgeInterfaces"
        cleanup
        Exit
    }

    <# Make sure the parameters don't match previous ESGs in the environment #>
    Write-Host "Polling exisiting edges from NSX environment for duplicate testing..."
    foreach ($edge in Get-NsxEdge) 
    {
        if ($(testNSXDuplicates $edge.Name $esgName "Error: Duplicate edge found in NSX"))
        {
            cleanup
            Exit
        }  
    } 

     <# Let's roll out the new ESG #>
    Write-Host "No duplicates found in environment. Adding edge to NSX..."

    try { New-NsxEdge -Name $esgName -Hostname $esgHostname -Datastore $(Get-Datastore -Name $dataStoreName) -ResourcePool $(Get-ResourcePool -Name $resourcePool) -Tenant $tenant -Interface $edgeIntUp, $edgeIntDlr -Username "" -Password "" -FwLoggingEnabled -FwEnabled -ErrorAction Stop }
    catch 
    {
        Write-Host "Error: Could not create ESG"
        $esgName = " "
        cleanup
        Exit
    }

    <# configure the ospf process #>
    try
    {
        New-NsxEdgeOspfArea -AreaId 1 -Type normal -EdgeRouting $(Get-NsxEdgerouting -Edge $(Get-NsxEdge $esgName)) -ErrorAction Stop
        Get-NsxEdge $esgName | Get-NsxEdgeRouting  | Set-NsxEdgerouting -EnableOspf -RouterId $esgUplinkPrimaryAddress | out-null -ErrorAction Stop
    }
    catch
    {
        Write-Host "Error: Unable to create OSPF process for ESG"
        cleanup2
        Exit
    }

    <# Add the OSPF configuration to the up/downstream interfaces to the ESG #>

    try
    {
        New-NsxEdgeOspfInterface -AreaId 1 -HelloInterval 10 -DeadInterval 40 -Priority 1 -Cost 1 -Vnic 0 -EdgeRouting $(Get-NsxEdgerouting -Edge $(Get-NsxEdge $esgName)) -ErrorAction Stop
        New-NsxEdgeOspfInterface -AreaId 1 -HelloInterval 10 -DeadInterval 40 -Priority 1 -Cost 1 -Vnic 1 -EdgeRouting $(Get-NsxEdgerouting -Edge $(Get-NsxEdge $esgName)) -ErrorAction Stop
    }
    catch
    {
        Write-Host "Error: Unable to enable OSPF on per Interface basis"
        cleanup
        Exit
    }
  

    <# Create uplink for DLR, and specify OSPF config #>
    <# procureIPRange(e.g. 24) #>
    try
    {
        $dlrInterfaceUplink = New-NsxLogicalRouterInterfaceSpec -Name "Uplink" -Type uplink -PrimaryAddress $(Read-Host "Enter address for dlr uplink") -SubnetPrefixLength $(Read-Host "Enter prefix length") -ConnectedTo $(Get-NsxLogicalSwitch $nameSwitchArgs[1]) -ErrorAction Stop
    }
    catch
    {
        Write-Host "Error: Unable to create DLR Uplink"
        cleanup
        Exit
    }

    $dlrNames           = "DMZ", "App", "DB"
    $dlrInterfaces      = @()

    <#Declare variables in main Scope#>
    for ($i = 0; $i -le 2; $i++)
    {
        <# procureIPRange(e.g. 24) #>

        try
        { 
            $dlrInterfaces[$i] = New-NsxLogicalRouterInterface -Name $dlrNames[$i] -Type internal -PrimaryAddress $(Read-Host "Enter $($dlrNames[$i]) interface primary address") -SubnetPrefixLength $(Read-Host "Enter subnet bits") -ConnectedTo  $(Get-NsxLogicalSwitch $nameSwitchArgs[$i+3]) -ErrorAction Stop
        }
        catch
        {
            cleanup
            Exit
        }
    }

    $dlrName = $(Read-Host "Enter the name of the DLR")
    Write-Host "Polling exisiting DLRs from NSX environment for duplicate testing..."

    <# check for duplicates #>
    foreach ($router in Get-NsxLogicalRouter) 
    { 
        if ($(testNSXDuplicates $router.Name $dlrName "Error: Duplicate router found in NSX"))
        {
            cleanup
            Exit
        }
    } 

    <# Let's roll out our DLR #>

    try
    {
        $dlr       = New-NsxLogicalRouter -Name $dlrName -Interface $dlrInterfaces[0], $dlrInterfaces[1], $dlrInterfaces[2] -Datastore $(Get-Datastore -Name $dataStoreName) -ResourcePool $(Get-ResourcePool -Name $resourcePool) -Tenant $tenant -ErrorAction Stop
    } 
    catch
    {
        Write-Host "Error: Unable to create DLR"
        $dlr = " "
        cleanup
        Exit
    }
    
    try { New-NsxLogicalRouterOspfInterface -HelloInterval 1- -DeadInterval 40 -AreaId 1 -Vnic dlrInterfaceUplink -ErrorAction Stop }
    catch
    {
        Write-Host "Error: Unable to create DLR OSPF Interface"
        cleanup
        Exit
    }

    try
    {
        <# Enable connected route redistribution into Area 1 #>
        $dlrRule = New-NsxLogicalRouterRedistributionRule -FromConnected $true -Action permit                           -ErrorAction Stop
        New-NsxLogicalRouterOspfArea -LogicalRouterRouting $dlrRule            -AreaId 1 -Type normal -Connection $dlr  -ErrorAction Stop
    }
    catch
    {
        Write-Host "Error: Unable to create OSPF redistribution rule and/or create logical routing area"
        cleanup
        Exit
    }
}

<#

    function:  testNSXDuplicates
    purpose:   compare two strings to test for a potential duplicate
    Arguments: three strings
    return:    void

#>
function testNSXDuplicates ([string] $strOne, [string] $strTwo, [string] $strErrorPrompt)
{
    if ($strOne -ceq $strTwo)
    {
        Write-Host "$($strErrorPrompt)" <# TODO: Post Error message to ServiceNow #>
        $nameOfDuplicate = $strOne
        return $true 
    }
    return $false
}

<#
    function:  cleanup
    purpose:   Perform NSX cleanup in case of error during script execution. We don't want to leave orphan objects
               within the NSX Manager!
    Arguments: None
    returns  : void

    notes:     We wanna be careful here. The point of the $nameOfDuplicate variable is so that we can test to see
               if we are wiping out the objects we just created during the programs lifetime (Which is what we want to do)
               versus wiping out a NSX object that was here prior to the programs execution (What we absolutely DO NOT want)
#>
function cleanup
{
    for ($i = 0; $i -le 5; $i++)
    {
        <# If a name was entered, and the name does not equal the duplicate we found, than remove it #>
        if ($nameSwitchArgs[$i] -ne " " -and $nameSwitchArgs[$i] -ne $nameOfDuplicate)
        {
            Write-Host "$($nameSwitchArgs[$i]) removed..."
            Remove-NsxLogicalSwitch $nameSwitchArgs[$i]
        }
    }

    if ($esgName -ne " " -and $esgName -ne $nameOfDuplicate)
    {
        Write-Host "$($esgName) removed..."
        Remove-NsxEdge $(Get-NsxEdge $esgName)
    }

    if ($dlrName -ne " " -and $dlrName -ne $nameOfDuplicate)
    {
        Write-Host "$($dlrName) removed..."
        Remove-NsxLogicalRouter $(Get-NsxLogicalRouter $dlrName)
    }

    <# TODO: Integrate Potential IPAM cleanup #>
}