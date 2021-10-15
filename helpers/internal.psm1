#region Analysis
Class MTU {
    [int] $MSS = '1472'

    MTU () {}
}

Class Reliability {
    # Min # of ICMP packets per path for a reliability test
    [int] $ICMPSent = '2000'

    # Minimum success percentage for a pass
    [int] $ICMPReliability = '99'

    # Minimum success percentage for a pass
    [int] $ICMPPacketLoss = '95'

    # Maximum Milliseconds for a pass
    [int] $ICMPLatency = '1.5'

    # Maximum jitter
    [Double] $ICMPJitter = '.1'

    Reliability () {}
}

Class TCPPerf {
        # Min TPUT by % of link speed
        [int] $TPUT = '85'

    TCPPerf () {}
}

Class NDKPerf {
        # Min TPUT by % of link speed
        [int] $TPUT = '90'

    NDKPerf () {}
}


# Stuff All Analysis Classes in Here
Class Analyzer {
    $MTU         = [MTU]::new()
    $Reliability = [Reliability]::new()
    $TCPPerf     = [TCPPerf]::new()
    $NDKPerf     = [NDKPerf]::new()

    Analyzer () {}
}
#endregion Analysis

<#
#region DataTypes
Class InterfaceDetails {
    [string] $Node
    [string] $InterfaceAlias
    [string] $InterfaceIndex
    [String] $IPAddress
    [String] $PrefixLength
    [String] $AddressState

    [String] $Network
    [String] $Subnet
    [String] $SubnetMask
    [String] $VLAN

    [string] $VMNetworkAdapterName
}
#endregion DataTypes
#>

#region Non-Exported Helpers
Function Convert-CIDRToMask {
    param (
        [Parameter(Mandatory = $true)]
        [int] $PrefixLength
    )

    $bitString = ('1' * $prefixLength).PadRight(32, '0')

    [String] $MaskString = @()

    for($i = 0; $i -lt 32; $i += 8){
        $byteString = $bitString.Substring($i,8)
        $MaskString += "$([Convert]::ToInt32($byteString, 2))."
    }

    Return $MaskString.TrimEnd('.')
}

Function Convert-MaskToCIDR {
    param (
        [Parameter(Mandatory = $true)]
        [IPAddress] $SubnetMask
    )

    [String] $binaryString = @()
    $SubnetMask.GetAddressBytes() | ForEach-Object { $binaryString += [Convert]::ToString($_, 2) }

    Return $binaryString.TrimEnd('0').Length
}

Function Convert-IPv4ToInt {
    Param (
        [Parameter(Mandatory = $true)]
        [IPAddress] $IPv4Address
    )

    $bytes = $IPv4Address.GetAddressBytes()

    Return [System.BitConverter]::ToUInt32($bytes,0)
}

Function Convert-IntToIPv4 {
    Param (
        [Parameter(Mandatory = $true)]
        [uint32]$Integer
    )

    $bytes = [System.BitConverter]::GetBytes($Integer)

    Return ([IPAddress]($bytes)).ToString()
}

Function Convert-NetworkATCIntentType {
    param ( $IntentType )

    # Define bitwise flags to figure out the specified intents per given intent
    [Flags()] enum IntentEnum {
        None       = 0
        Compute    = 2
        Storage    = 4
        Management = 8
    }

    $IntentType | ForEach-Object {
        $thisIntentType = $_
        $intentsContained = [enum]::GetValues([IntentEnum]) | Where-Object { $_.value__ -band $thisIntentType }
    }

    return $intentsContained
}
#endregion Non-Exported Helpers

#region Helper Functions
Function Get-ConnectivityMapping {
    param (
        [string[]] $Nodes    ,
        [string[]] $IPTarget ,
        [string]   $LogFile  ,
        [Switch]   $DontCheckATC
   )

    $EthernetMapping = @()
    $RDMAMapping     = @()

    $ClusRes = Get-ClusterResource -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where { $_.OwnerGroup -eq 'Cluster Group' -and $_.ResourceType -eq 'IP Address' }
    $ClusterIPs = ($ClusRes | Get-ClusterParameter -ErrorAction SilentlyContinue -Name Address).Value

    foreach ($IP in $IPTarget) {
        $thisNode = (Resolve-DnsName -Name $IP -DnsOnly).NameHost.Split('.')[0]

        if ($thisNode) { # Resolution Available
            # Since ATC relies on a domain join, we'll assume that a specified IP target means the we're not going to check ATC adapters.
            if ($thisNode -eq $env:COMPUTERNAME) {
                $AdapterIP = Get-NetIPAddress -IPAddress $IP -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred, Invalid, Duplicate |
                                Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                $RDMAAdapter = (Get-NetAdapterRdma -Name "*" -ErrorAction SilentlyContinue | Where Enabled -eq $true).Name

                # Remove APIPA
                $AdapterIP = $AdapterIP | Where IPAddress -NotLike '169.254.*'

                $NetAdapter = Get-NetAdapter -InterfaceIndex $AdapterIP.InterfaceIndex
                $VMNetworkAdapter = Get-VMNetworkAdapter -ManagementOS | Where DeviceID -in $NetAdapter.DeviceID
            }
            else {
                # Do Not use Invoke-Command here. In the current build nested properties are not preserved and become strings
                $AdapterIP = Get-NetIPAddress -IPAddress $IP -CimSession $thisNode -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred |
                                Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                $RDMAAdapter = (Get-NetAdapterRdma -CimSession $thisNode -Name "*" -ErrorAction SilentlyContinue | Where Enabled -eq $true).Name

                # Remove APIPA
                $AdapterIP = $AdapterIP | Where IPAddress -NotLike '169.254.*'

                $NetAdapter = Get-NetAdapter -CimSession $thisNode -InterfaceIndex $AdapterIP.InterfaceIndex
                $VMNetworkAdapter = Get-VMNetworkAdapter -CimSession $thisNode -ManagementOS | Where DeviceID -in $NetAdapter.DeviceID
            }

            $EthernetNodeOutput = @()
            $RDMANodeOutput     = @()

            foreach ($thisAdapterIP in ($AdapterIP | Where IPAddress -NotIn $ClusterIPs)) {
                $EthernetResult = New-Object -TypeName psobject
                $RDMAResult     = New-Object -TypeName psobject

                $thisNetAdapter       = $NetAdapter       | Where InterfaceIndex -eq $thisAdapterIP.InterfaceIndex
                $thisVMNetworkAdapter = $VMNetworkAdapter | Where DeviceID -EQ $thisNetAdapter.DeviceID

                $EthernetResult | Add-Member -MemberType NoteProperty -Name NodeName -Value $thisNode
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name NodeName -Value $thisNode

                $EthernetResult | Add-Member -MemberType NoteProperty -Name InterfaceAlias -Value $thisAdapterIP.InterfaceAlias
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name InterfaceAlias -Value $thisAdapterIP.InterfaceAlias

                $EthernetResult | Add-Member -MemberType NoteProperty -Name InterfaceIndex -Value $thisAdapterIP.InterfaceIndex
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name InterfaceIndex -Value $thisAdapterIP.InterfaceIndex

                $EthernetResult | Add-Member -MemberType NoteProperty -Name IPAddress -Value $thisAdapterIP.IPAddress
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name IPAddress -Value $thisAdapterIP.IPAddress

                $EthernetResult | Add-Member -MemberType NoteProperty -Name PrefixLength -Value $thisAdapterIP.PrefixLength
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name PrefixLength -Value $thisAdapterIP.PrefixLength

                # We don't need these for RDMAResult
                $EthernetResult | Add-Member -MemberType NoteProperty -Name AddressState -Value $thisAdapterIP.AddressState
                $EthernetResult | Add-Member -MemberType NoteProperty -Name InterfaceDescription -Value $thisNetAdapter.InterfaceDescription

                $EthernetResult | Add-Member -MemberType NoteProperty -Name LinkSpeed -Value $thisNetAdapter.LinkSpeed
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name LinkSpeed -Value $thisNetAdapter.LinkSpeed

                #TODO: Create a warning that indicates we can't establish if this is the correct network.
                if ($thisNetAdapter.Name -in $RDMAAdapter) { $RDMAResult | Add-Member -MemberType NoteProperty -Name RDMAEnabled -Value $true }
                else { $RDMAResult | Add-Member -MemberType NoteProperty -Name RDMAEnabled -Value $false }

                $SubnetMask  = Convert-CIDRToMask -PrefixLength $thisAdapterIP.PrefixLength
                $SubNetInInt = Convert-IPv4ToInt  -IPv4Address  $SubnetMask
                $IPInInt     = Convert-IPv4ToInt  -IPv4Address  $thisAdapterIP.IPAddress

                $Network    = Convert-IntToIPv4 -Integer ($SubNetInInt -band $IPInInt)
                $Subnet     = "$($Network)/$($thisAdapterIP.PrefixLength)"

                $EthernetResult | Add-Member -MemberType NoteProperty -Name SubnetMask -Value $SubnetMask
                $EthernetResult | Add-Member -MemberType NoteProperty -Name Network    -Value $Network
                $EthernetResult | Add-Member -MemberType NoteProperty -Name Subnet     -Value $Subnet

                $RDMAResult | Add-Member -MemberType NoteProperty -Name SubnetMask -Value $SubnetMask
                $RDMAResult | Add-Member -MemberType NoteProperty -Name Network    -Value $Network
                $RDMAResult | Add-Member -MemberType NoteProperty -Name Subnet     -Value $Subnet

                if ($thisVMNetworkAdapter) {
                    $EthernetResult | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value $thisVMNetworkAdapter.Name
                    $RDMAResult     | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value $thisVMNetworkAdapter.Name

                    if ($thisVMNetworkAdapter.IsolationSetting.IsolationMode -eq 'VLAN') {
                        $VLAN = $thisVMNetworkAdapter.IsolationSetting.DefaultIsolationID
                    }
                    elseif ($thisVMNetworkAdapter.VlanSetting.OperationMode -eq 'Access') {
                        $VLAN = $thisVMNetworkAdapter.VlanSetting.AccessVlanId
                    }
                    elseif ($thisVMNetworkAdapter.IsolationSetting.IsolationMode -eq 'None' -and
                            $thisVMNetworkAdapter.VlanSetting.OperationMode -eq 'Untagged') {
                            $VLAN = '0'
                    }
                    else { $thisInterfaceDetails.VLAN = 'Unsupported by Test-NetStack' }
                }
                else {
                    $EthernetResult | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value 'Not Applicable'
                    $RDMAResult     | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value 'Not Applicable'

                    if ($thisNetAdapter.VlanID -in 0..4095) { $VLAN = $thisNetAdapter.VlanID }
                    else { $VLAN = 'Unsupported' } # In this case, the adapter does not support VLANs
                }

                $EthernetResult | Add-Member -MemberType NoteProperty -Name VLAN -Value $VLAN
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name VLAN -Value $VLAN

                $EthernetNodeOutput += $EthernetResult
                $RDMANodeOutput     += $RDMAResult
            }
        }
        else { # No DNS Available; we should never get here if the prerequisites do their job
            throw 'DNS Not available; required for remoting and to identify realistic system expectations.'
        }

        $EthernetMapping += $EthernetNodeOutput
        $RDMAMapping     += $RDMANodeOutput

        Remove-Variable AdapterIP, NetAdapter, VMNetworkAdapter, RDMAAdapter -ErrorAction SilentlyContinue
    }

    # ATC is only applicable to the nodes code path. With this, we can know if the nodes were supposed to have RDMA enabled.
    if (-not($DontCheckATC)) {
        $ATCIntentData = Get-NetworkATCAdapters
        $AdapterNames  = $ATCIntentData.Adapters + $ATCIntentData.ManagementvNIC + $ATCIntentData.StoragevNIC

        if (-not ($ATCIntentData)) {
            'No Network ATC intents were found. To resolve this issue, verify that you are using an account with access to the local cluster or use the DontCheckATC switch.' | Out-File $LogFile -Append -Encoding utf8 -Width 2000
            $NetStackResults.Prerequisites | ft * | Out-File $LogFile -Append -Encoding utf8 -Width 2000
            throw 'No Network ATC intents were found. To resolve this issue, verify that you are using an account with access to the local cluster or use the DontCheckATC switch.'
        }
        else {
            foreach ($intent in $ATCIntentData) {
                if ( 'Storage' -in $ATCIntentData.IntentType ) { # There can be only 1 storage intent so this will zip through quickly
                    $StorageAdapters = $ATCIntentData.Adapters + $ATCIntentData.StoragevNIC
                }
            }
        }
    }

    foreach ($thisNode in $Nodes) {
        if ($thisNode -eq $env:COMPUTERNAME) {
            if ($DontCheckATC) {
                $AdapterIP = Get-NetIPAddress -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred, Invalid, Duplicate |
                                Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                $RDMAAdapter = (Get-NetAdapterRdma -Name "*" -ErrorAction SilentlyContinue | Where Enabled -eq $true).Name

                # We only want to do this in this path, as we don't want to remove APIPA adapters from ATC adapters. This could indicate a misconfiguration
                $AdapterIP = $AdapterIP | Where IPAddress -NotLike '169.254.*' # Remove APIPA
            }
            else {
                $AdapterIP = Get-NetIPAddress -InterfaceAlias $AdapterNames -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred, Invalid, Duplicate |
                                Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                $RDMAAdapter = (Get-NetAdapterRdma -Name $StorageAdapters -ErrorAction SilentlyContinue | Where Enabled -eq $true).Name
            }

            $NetAdapter = Get-NetAdapter -InterfaceIndex $AdapterIP.InterfaceIndex
            $VMNetworkAdapter = Get-VMNetworkAdapter -ManagementOS | Where DeviceID -in $NetAdapter.DeviceID
        }
        else {
            if ($DontCheckATC) {
                # Do Not use Invoke-Command here. In the current build nested properties are not preserved and become strings
                $AdapterIP = Get-NetIPAddress -CimSession $thisNode -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred |
                                Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                $RDMAAdapter = (Get-NetAdapterRdma -CimSession $thisNode -Name "*" -ErrorAction SilentlyContinue | Where Enabled -eq $true).Name

                # We only want to do this in this path, as we don't want to remove APIPA adapters from ATC adapters. This could indicate a misconfiguration
                $AdapterIP = $AdapterIP | Where IPAddress -NotLike '169.254.*' # Remove APIPA
            }
            else {
                # Do Not use Invoke-Command here. In the current build nested properties are not preserved and become strings
                # Since this is looking for ATC adapters, it's safe to send it all adapters even if not bound to TCPIP (e.g. teamed adapters)
                $AdapterIP = Get-NetIPAddress -InterfaceAlias $AdapterNames -CimSession $thisNode -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred |
                                Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                $RDMAAdapter = (Get-NetAdapterRdma -CimSession $thisNode -Name $StorageAdapters -ErrorAction SilentlyContinue | Where Enabled -eq $true).Name
            }

            $NetAdapter = Get-NetAdapter -CimSession $thisNode -InterfaceIndex $AdapterIP.InterfaceIndex
            $VMNetworkAdapter = Get-VMNetworkAdapter -CimSession $thisNode -ManagementOS | Where DeviceID -in $NetAdapter.DeviceID
        }

        $EthernetNodeOutput = @()
        $RDMANodeOutput     = @()

        foreach ($thisAdapterIP in ($AdapterIP | Where IPAddress -NotIn $ClusterIPs)) {
            $EthernetResult = New-Object -TypeName psobject
            $RDMAResult     = New-Object -TypeName psobject

            $thisNetAdapter       = $NetAdapter       | Where InterfaceIndex -eq $thisAdapterIP.InterfaceIndex
            $thisVMNetworkAdapter = $VMNetworkAdapter | Where DeviceID -eq $thisNetAdapter.DeviceID

            $EthernetResult | Add-Member -MemberType NoteProperty -Name NodeName -Value $thisNode
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name NodeName -Value $thisNode

            $EthernetResult | Add-Member -MemberType NoteProperty -Name InterfaceAlias -Value $thisAdapterIP.InterfaceAlias
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name InterfaceAlias -Value $thisAdapterIP.InterfaceAlias

            $EthernetResult | Add-Member -MemberType NoteProperty -Name InterfaceIndex -Value $thisAdapterIP.InterfaceIndex
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name InterfaceIndex -Value $thisAdapterIP.InterfaceIndex

            $EthernetResult | Add-Member -MemberType NoteProperty -Name IPAddress -Value $thisAdapterIP.IPAddress
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name IPAddress -Value $thisAdapterIP.IPAddress

            $EthernetResult | Add-Member -MemberType NoteProperty -Name PrefixLength -Value $thisAdapterIP.PrefixLength
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name PrefixLength -Value $thisAdapterIP.PrefixLength

            $EthernetResult | Add-Member -MemberType NoteProperty -Name AddressState -Value $thisAdapterIP.AddressState
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name AddressState -Value $thisAdapterIP.AddressState

            $EthernetResult | Add-Member -MemberType NoteProperty -Name InterfaceDescription -Value $thisNetAdapter.InterfaceDescription
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name InterfaceDescription -Value $thisNetAdapter.InterfaceDescription

            $EthernetResult | Add-Member -MemberType NoteProperty -Name LinkSpeed -Value $thisNetAdapter.LinkSpeed
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name LinkSpeed -Value $thisNetAdapter.LinkSpeed

            if ($thisNetAdapter.Name -in $RDMAAdapter) { $RDMAResult | Add-Member -MemberType NoteProperty -Name RDMAEnabled -Value $true }
            else { $RDMAResult | Add-Member -MemberType NoteProperty -Name RDMAEnabled -Value $false }

            $SubnetMask  = Convert-CIDRToMask -PrefixLength $thisAdapterIP.PrefixLength
            $SubNetInInt = Convert-IPv4ToInt  -IPv4Address  $SubnetMask
            $IPInInt     = Convert-IPv4ToInt  -IPv4Address  $thisAdapterIP.IPAddress
            $Network     = Convert-IntToIPv4 -Integer ($SubNetInInt -band $IPInInt)
            $Subnet      = "$($Network)/$($thisAdapterIP.PrefixLength)"

            $EthernetResult | Add-Member -MemberType NoteProperty -Name SubnetMask -Value $SubnetMask
            $EthernetResult | Add-Member -MemberType NoteProperty -Name Network    -Value $Network
            $EthernetResult | Add-Member -MemberType NoteProperty -Name Subnet     -Value $Subnet

            $RDMAResult | Add-Member -MemberType NoteProperty -Name SubnetMask -Value $SubnetMask
            $RDMAResult | Add-Member -MemberType NoteProperty -Name Network    -Value $Network
            $RDMAResult | Add-Member -MemberType NoteProperty -Name Subnet     -Value $Subnet

            if ($thisVMNetworkAdapter) {
                $EthernetResult | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value $thisVMNetworkAdapter.Name
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value $thisVMNetworkAdapter.Name

                if ($thisVMNetworkAdapter.IsolationSetting.IsolationMode -eq 'VLAN') {
                    $VLAN = $thisVMNetworkAdapter.IsolationSetting.DefaultIsolationID
                }
                elseif ($thisVMNetworkAdapter.VlanSetting.OperationMode -eq 'Access') {
                    $VLAN = $thisVMNetworkAdapter.VlanSetting.AccessVlanId
                }
                elseif ($thisVMNetworkAdapter.IsolationSetting.IsolationMode -eq 'None' -and
                        $thisVMNetworkAdapter.VlanSetting.OperationMode -eq 'Untagged') {
                        $VLAN = '0'
                }
                else { $thisInterfaceDetails.VLAN = 'Unsupported by Test-NetStack' }
            }
            else {
                $EthernetResult | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value 'Not Applicable'
                $RDMAResult     | Add-Member -MemberType NoteProperty -Name VMNetworkAdapterName -Value 'Not Applicable'

                if ($thisNetAdapter.VlanID -in 0..4095) { $VLAN = $thisNetAdapter.VlanID }
                else { $VLAN = 'Unsupported' } # In this case, the adapter does not support VLANs
            }

            $EthernetResult | Add-Member -MemberType NoteProperty -Name VLAN -Value $VLAN
            $RDMAResult     | Add-Member -MemberType NoteProperty -Name VLAN -Value $VLAN

            $EthernetNodeOutput += $EthernetResult
            $RDMANodeOutput     += $RDMAResult
        }

        $EthernetMapping += $EthernetNodeOutput
        $RDMAMapping     += $RDMANodeOutput

        Remove-Variable AdapterIP, NetAdapter, VMNetworkAdapter, RDMAAdapter -ErrorAction SilentlyContinue
    }

   Return $EthernetMapping, $RDMAMapping
}

Function Get-TestableNetworksFromMapping {
    param ( $Mapping )

    $VLANSupportedNets = $Mapping | Where-Object VLAN -ne 'Unsupported' | Group-Object Subnet, VLAN
    $UsableNetworks    = $VLANSupportedNets | Where-Object {
        $_.Count -ge 1 -and (($_.Group.NodeName | Select-Object -Unique).Count) -eq $($Mapping.NodeName | Select-Object -Unique).Count
    }

    if ($UsableNetworks) { Return $UsableNetworks }
    else { Return 'None Available' }
}

Function Get-DisqualifiedNetworksFromMapping {
    param ( $Mapping )

    $VLANSupportedNets = $Mapping | Where-Object VLAN -ne 'Unsupported' | Group-Object Subnet, VLAN

    $DisqualifiedByInterfaceCount = $VLANSupportedNets | Where-Object Count -eq 1

    $DisqualifiedByNetworkAsymmetry = $VLANSupportedNets | Where-Object { $_.Count -ge 1 -and
        (($_.Group.NodeName | Select -Unique).Count) -ne $($Mapping.NodeName | Select -Unique).Count }

    $DisqualifiedByVLANSupport    = $Mapping | Where-Object VLAN -eq 'Unsupported' | Group-Object Subnet, VLAN

    $Disqualified = New-Object -TypeName psobject
    if ($DisqualifiedByVLANSupport) {
        $Disqualified | Add-Member -MemberType NoteProperty -Name NoVLANOnInterface -Value $DisqualifiedByVLANSupport
    }

    if ($DisqualifiedByInterfaceCount) {
        $Disqualified | Add-Member -MemberType NoteProperty -Name OneInterfaceInSubnet -Value $DisqualifiedByInterfaceCount
    }

    if ($DisqualifiedByNetworkAsymmetry) {
        $Disqualified | Add-Member -MemberType NoteProperty -Name AsymmetricNetwork -Value $DisqualifiedByNetworkAsymmetry
    }

    Return $Disqualified
}

Function Get-PhysicalMapping {
    param (
        [string[]] $Nodes    ,
        [string[]] $IPTarget ,
        [string]   $LogFile  ,

        # Default for this function is to get all adapters as required by Test-NetStack.
        # However this function can be called by other scenarios (e.g. ATC) and needs to support the physical mapping of ATC adapters only.
        [Switch] $DontCheckATC = $true
    )

    if ($DontCheckATC -eq $false) { # By default, this path should not be engaged because we want the full physical map
        $ATCIntentData = Get-NetworkATCAdapters

        # I think we only need the physical adapters here
        $AdapterNames  = $ATCIntentData.Adapters # + $ATCIntentData.ManagementvNIC + $ATCIntentData.StoragevNIC
    }

    $PhysicalMapping = New-Object -TypeName psobject
    foreach ($thisNode in $Nodes) {
        $FabricInfo = @() # FabricInfo will carry the list of information from a specific node

        if ($thisNode -eq $env:COMPUTERNAME) {
            if ($DontCheckATC) { # Do not remove APIPA here as we can still get physical mapping
                $AdapterNames = (Get-NetAdapter | Where {$_.MediaType -eq '802.3' -and $_.Status -eq 'Up' -and $_.DriverFileName -notlike '*KDNIC.sys*'}).Name

                # We also need to get the remote adapter names
                $remoteAdapters = @()
                $remoteAdapters += Invoke-Command -ComputerName ($Nodes -ne $thisNode) -ScriptBlock {
                    (Get-NetAdapter | Where {$_.MediaType -eq '802.3' -and $_.Status -eq 'Up' -and
                                             $_.DriverFileName -notlike '*KDNIC.sys*'}) | Select PSComputerName, Name, MacAddress
                }
            }
            else {
                # We do not need to get the remote adapter names because they will be the same if included in ATC
                # We already have the adapternames from ATC run earlier
            }

            $FabricInfo = Get-FabricInfo -InterfaceNames $localAdapterNames -ErrorAction SilentlyContinue

            #$RemoteAdaptersNormalizedMAC = $RemoteAdapters | ForEach-Object {$_.MacAddress -replace '-', ':'}


            ($FabricInfo.GetEnumerator() | Where Key -ne 'ChassisGroups' | ForEach-Object { $FabricInfo.$($_.Key) }).Fabric.PortID

            #$B2BSrcMac = $RemoteAdapters | Where-Object {$_.MacAddress.Replace('-', ':') -like `
            #                                             $FabricInfo.$thisInterfaceName.Fabric.SourceMac }

            $B2BSrcMac = $RemoteAdapters | Foreach-Object { $_ | Where-Object {$_.MacAddress.Replace('-', ':') -like `
                                                            $FabricInfo.GetEnumerator() | Where Key -ne 'ChassisGroups' | ForEach-Object {
                                                                $FabricInfo.$($_.Key)
                                                            }
                                                        }
        }
        else {
            if ($DontCheckATC) { # Do not remove APIPA here as we can still get physical mapping
                # Do Not use Invoke-Command here. In the current build nested properties are not preserved and become strings
                $AdapterNames = (Get-NetAdapter -CimSession $thisNode | Where {$_.MediaType -eq '802.3' -and $_.Status -eq 'Up' -and $_.DriverFileName -notlike '*KDNIC.sys*'}).Name
                #$AdapterIP = Get-NetIPAddress -CimSession $thisNode -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred |
                #                    Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                # We also need to get the remote adapter names
            }
            else {
                # Do Not use Invoke-Command here. In the current build nested properties are not preserved and become strings
                # Since this is looking for ATC adapters, it's safe to send it all adapters even if not bound to TCPIP (e.g. teamed adapters)
                #$AdapterIP = Get-NetIPAddress -InterfaceAlias $AdapterNames -CimSession $thisNode -AddressFamily IPv4 -SuffixOrigin Dhcp, Manual -AddressState Preferred |
                #                    Select InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState

                # We do not need to get the remote adapter names because they will be the same if included in ATC
            }

            $FabricInfo = Invoke-Command -ComputerName $thisNode -ScriptBlock {
                Get-FabricInfo -InterfaceNames $($using:AdapterNames) -ErrorAction SilentlyContinue
            }
        }

        $B2BSrcMac = $RemoteAdapter | Where-Object {$_.MacAddress.Replace('-', ':') -like $FabricInfo.$thisInterfaceName.Fabric.SourceMac}

        $PhysicalMapping | Add-Member -MemberType NoteProperty -Name $thisNode -Value $FabricInfo
        Remove-Variable -Name FabricInfo -ErrorAction SilentlyContinue
    }






    $Mapping.Group | ForEach-Object {
        $thisSource = $_
        $thisSourceName = $thisSource.Name

        $B2BSrcMac = $Mapping.Group | Where-Object NodeName -ne $thisSource.NodeName | Where-Object {$_.MacAddress.Replace('-', ':') -like $FabricInfo.$thisSourceName.Fabric.SourceMac}
        if ($B2BSrcMac) {
            $thisSwitchlessMapping = New-Object -TypeName psobject
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name SystemName -Value $Env:COMPUTERNAME
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name LocalNIC   -Value $FabricInfo.$thisSourceName.Fabric.InterfaceName
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name LocalMac   -Value $($thisSource.MacAddress -replace '-', ':')

            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name Connection -Value 'Switchless'
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name SubNet     -Value $FabricInfo.$thisSourceName.InterfaceDetails.Subnet
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name VLAN       -Value $FabricInfo.$thisSourceName.InterfaceDetails.VLAN

            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name RemoteSystem    -Value $B2BSrcMac.PSComputerName
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name RemoteName      -Value $B2BSrcMac.Name
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name RemoteChassisID -Value $FabricInfo.$thisSourceName.Fabric.ChassisID
            $thisSwitchlessMapping | Add-Member -MemberType NoteProperty -Name RemoteMac       -Value $B2BSrcMac.MacAddress

            $Mapping += $thisSwitchlessMapping
        }
        else { # not switchless, check if connected to same rack
            $thisSwitchedMapping = New-Object -TypeName psobject
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name SystemName -Value $Env:COMPUTERNAME

            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name LocalNIC -Value $FabricInfo.$thisSourceName.Fabric.InterfaceName
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name LocalMac -Value $($thisSource.MacAddress -replace '-', ':')

            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name Connection -Value 'Switched'
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name SubNet     -Value $FabricInfo.$thisSourceName.InterfaceDetails.Subnet
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name VLAN       -Value $FabricInfo.$thisSourceName.InterfaceDetails.VLAN

            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name RemoteSystem -Value $FabricInfo.$thisSourceName.Fabric.SystemName
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name RemoteName   -Value $FabricInfo.$thisSourceName.Fabric.PortID
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name RemoteChassisID -Value $FabricInfo.$thisSourceName.Fabric.ChassisID
            $thisSwitchedMapping | Add-Member -MemberType NoteProperty -Name RemoteMac       -Value $($FabricInfo.$thisSourceName.Fabric.sourceMac -replace '-', ':')

            $Mapping += $thisSwitchedMapping
        }
    }
}

Function Get-RunspaceGroups {
    param ( $TestableNetworks )
    # create list of all valid source->target pairs
    $allPairs = @()
    $TestableNetworks | ForEach-Object {
        $thisTestableNet = $_
        $thisTestableNet.Group | ForEach-Object {
            $thisSource = $_
            $thisTestableNet.Group | Where-Object NodeName -ne $thisSource.NodeName | ForEach-Object {
                $thisTarget = $_
                $thisPair = New-Object -TypeName psobject
                $thisPair | Add-Member -MemberType NoteProperty -Name Source -Value $thisSource
                $thisPair | Add-Member -MemberType NoteProperty -Name Target -Value $thisTarget
                $allPairs += $thisPair
            }
        }
    }

    # build up groups of pairs that can be run simultaneously - no common elements
    $runspaceGroups = @()
    while ($allPairs -ne $null) {
        $allPairs | ForEach-Object {
            $thisPair = $_
            $added = $false
            for ($i = 0; $i -lt $runspaceGroups.Count; $i++) {
                $invalidGroup = $false
                foreach ($pair in $runspaceGroups[$i]) {
                    if (($pair.Source -eq $thisPair.Source) -or ($pair.Target -eq $thisPair.Target) -or ($pair.Source -eq $thisPair.Target) -or ($pair.Target -eq $thisPair.Source)) {
                        $invalidGroup = $true
                    }
                }
                if (!$invalidGroup -and !$added) {
                    $runspaceGroups[$i] += $thisPair
                    $added = $true
                }
            }
            if (!$added) {
                $runspaceGroups += , @($thisPair)
            }
            $allPairs = $allPairs -ne $thisPair
        }
    }

    Return $runspaceGroups
}

Function Get-Jitter {
    <#
    .SYNOPSIS
        This function takes input as a list of roundtriptimes and returns the jitter
    #>

    param (
        [String[]] $RoundTripTime
    )

    0..($RoundTripTime.Count - 1) | ForEach-Object {
        $Iteration = $_

        $Difference = $RoundTripTime[$Iteration] - $RoundTripTime[$Iteration + 1]
        $RTTDif += [Math]::Abs($Difference)
    }

    return ($RTTDif / $RoundTripTime.Count).ToString('.#####')
}

Function Get-Latency {
    <#
    .SYNOPSIS
        This function takes input as a list of roundtriptimes and returns the latency

    .Description
        This function assumes that input is in ms. Since LAT must be > 0 and ICMP only provides ms precision, we normalize 0 to 1s
        This function assumes that all input was successful. Scrub input before sending to this function.
    #>

    param (
        [String[]] $RoundTripTime
    )

    $RTTNormalized = @()
    $RTTNormalized = $RoundTripTime -replace 0, 1
    $RTTNormalized | ForEach-Object { [int] $RTTNumerator = $RTTNumerator + $_ }

    return ($RTTNumerator / $RTTNormalized.Count).ToString('.###')

}

Function Get-Failures {
    param ( $NetStackResults )
    $HostNames = $NetStackResults.TestableNetworks.Group.NodeName | Select-Object -Unique
    $Interfaces = $NetStackResults.TestableNetworks.Group.IPAddress | Select-Object -Unique
    $Failures = New-Object -TypeName psobject
    $NetStackResults.PSObject.Properties | ForEach-Object {
        if ($_.Name -like 'Stage1') {
            $Stage1Results = $_.Value

            $IndividualFailures = @()
            $AllFailures = $Stage1Results | Where-Object PathStatus -eq Fail
            $AllFailures | ForEach-Object {
                $IndividualFailures += "($($_.SourceHostName)) $($_.Source) -> $($_.Destination)"
            }

            $InterfaceFailures = @()
            $Interfaces | ForEach-Object {
                $thisInterface = $_
                $thisInterfaceResults = $Stage1Results | Where-Object Source -eq $thisInterface
                if ($thisInterfaceResults.PathStatus -notcontains "Pass") {
                    $InterfaceFailures += $thisInterface
                }
            }

            $MachineFailures = @()
            $HostNames | ForEach-Object {
                $thisHost = $_
                $thisMachineResults = $Stage1Results | Where-Object SourceHostName -eq $thisHost
                if ($thisMachineResults.PathStatus -notcontains "Pass") {
                    $MachineFailures += $thisHost
                }
            }

            $Stage1Failures = New-Object -TypeName psobject
            $Stage1HadFailures = $false
            if ($IndividualFailures.Count -gt 0) {
                $Stage1Failures | Add-Member -MemberType NoteProperty -Name IndividualFailures -Value $IndividualFailures
                $Stage1HadFailures = $true
            }
            if ($InterfaceFailures.Count -gt 0) {
                $Stage1Failures | Add-Member -MemberType NoteProperty -Name InterfaceFailures -Value $InterfaceFailures
                $Stage1HadFailures = $true
            }
            if ($MachineFailures.Count -gt 0) {
                $Stage1Failures | Add-Member -MemberType NoteProperty -Name MachineFailures -Value $MachineFailures
                $Stage1HadFailures = $true
            }
            if ($Stage1HadFailures) {
                $Failures | Add-Member -MemberType NoteProperty -Name Stage1 -Value $Stage1Failures
            }
        } elseif (($_.Name -like 'Stage2') -or ($_.Name -like 'Stage3') -or ($_.Name -like 'Stage4')) {
            $StageResults = $_.Value
            $IndividualFailures = @()
            $AllFailures = $StageResults | Where-Object PathStatus -eq Fail
            $AllFailures | ForEach-Object {
                $IndividualFailures += "$($_.Sender) -> $($_.Receiver) ($($_.ReceiverHostName))"
            }

            $InterfaceFailures = @()
            $Interfaces | ForEach-Object {
                $thisInterface = $_
                $thisInterfaceResults = $StageResults | Where-Object Receiver -eq $thisInterface
                if ($thisInterfaceResults.PathStatus -notcontains "Pass") {
                    $InterfaceFailures += $thisInterface
                }
            }

            $MachineFailures = @()
            $HostNames | ForEach-Object {
                $thisHost = $_
                $thisMachineResults = $StageResults | Where-Object ReceiverHostName -eq $thisHost
                if ($thisMachineResults.PathStatus -notcontains "Pass") {
                    $MachineFailures += $thisHost
                }
            }

            $StageFailures = New-Object -TypeName psobject
            $StageHadFailures = $false
            if ($IndividualFailures.Count -gt 0) {
                $StageFailures | Add-Member -MemberType NoteProperty -Name IndividualFailures -Value $IndividualFailures
                $StageHadFailures = $true
            }
            if ($InterfaceFailures.Count -gt 0) {
                $StageFailures | Add-Member -MemberType NoteProperty -Name InterfaceFailures -Value $InterfaceFailures
                $StageHadFailures = $true
            }
            if ($MachineFailures.Count -gt 0) {
                $StageFailures | Add-Member -MemberType NoteProperty -Name MachineFailures -Value $MachineFailures
                $StageHadFailures = $true
            }
            if ($StageHadFailures) {
                $Failures | Add-Member -MemberType NoteProperty -Name $_.Name -Value $StageFailures
            }
        } elseif ($_.Name -like 'Stage5') {
            $StageResults = $_.Value

            $InterfaceFailures = @()
            $Interfaces | ForEach-Object {
                $thisInterface = $_
                $thisInterfaceResults = $StageResults | Where-Object Receiver -eq $thisInterface
                if ($thisInterfaceResults.ReceiverStatus -notcontains "Pass") {
                    $InterfaceFailures += $thisInterface
                }
            }

            $MachineFailures = @()
            $HostNames | ForEach-Object {
                $thisHost = $_
                $thisMachineResults = $StageResults | Where-Object ReceiverHostName -eq $thisHost
                if ($thisMachineResults.ReceiverStatus -notcontains "Pass") {
                    $MachineFailures += $thisHost
                }
            }

            $StageFailures = New-Object -TypeName psobject
            $StageHadFailures = $false
            if ($InterfaceFailures.Count -gt 0) {
                $StageFailures | Add-Member -MemberType NoteProperty -Name InterfaceFailures -Value $InterfaceFailures
                $StageHadFailures = $true
            }
            if ($MachineFailures.Count -gt 0) {
                $StageFailures | Add-Member -MemberType NoteProperty -Name MachineFailures -Value $MachineFailures
                $StageHadFailures = $true
            }
            if ($StageHadFailures) {
                $Failures | Add-Member -MemberType NoteProperty -Name $_.Name -Value $StageFailures
            }
        } elseif ($_.Name -like 'Stage6') {
            $StageResults = $_.Value

            $NetworkFailures = @()
            $AllFailures = $StageResults | Where-Object NetworkStatus -eq Fail
            $AllFailures | ForEach-Object {
                $NetworkFailures += "Subnet $($_.subnet) VLAN $($_.VLAN)"
            }

            $StageFailures = New-Object -TypeName psobject
            $StageHadFailures = $false
            if ($NetworkFailures.Count -gt 0) {
                $StageFailures | Add-Member -MemberType NoteProperty -Name NetworkFailures -Value $NetworkFailures
                $StageHadFailures = $true
            }
            if ($StageHadFailures) {
                $Failures | Add-Member -MemberType NoteProperty -Name $_.Name -Value $StageFailures
            }

        }
    }
    Return $Failures
}

Function Write-RecommendationsToLogFile {
    param (
        $NetStackResults,
        $LogFile
    )

    "Failure Recommendations`n" | Out-File $LogFile -Append -Encoding utf8 -Width 2000

    $ModuleBase = (Get-Module Test-NetStack -ListAvailable | Select-Object -First 1).ModuleBase

    $NetStackResults.PSObject.Properties | Where-Object { $_.Name -like 'Stage*' } | ForEach-Object {
        if ($NetStackResults.Failures.PSObject.Properties.Name -contains $_.Name) {
                "$($_.Name) Failure Recommendations`n" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                switch ($_.Name) {
                'Stage1' {
                    if ($NetStackResults.Failures.Stage1.PSObject.Properties.Name -contains "IndividualFailures") {
                        "Individual Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Connectivity and PMTUD failed across the following connections:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage1.IndividualFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify subnet, VLAN, and MTU settings for relevant NICs." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage1.PSObject.Properties.Name -contains "InterfaceFailures") {
                        "`nInterface Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Connectivity and PMTUD failed across all target NICs for the following source NICs:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage1.InterfaceFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify subnet, VLAN, and MTU settings for relevant NICs. If the problem persists, consider checking NIC cabling or physical interlinks."  | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage1.PSObject.Properties.Name -contains "MachineFailures") {
                        "`nMachine Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Connectivity and PMTUD failed across all target machines for the following source machines:"  | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage1.MachineFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify firewall and MTU settings for the erring machines. If the problem persists, consider checking the machine cabling, NIC cabling, or physical interlinks."  | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                }
                'Stage2' {
                    if ($NetStackResults.Failures.Stage2.PSObject.Properties.Name -contains "IndividualFailures") {
                        "Individual Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "TCP throughput failed to meet threshold across the following connections:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage2.IndividualFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Retry TCP transaction with repro commands. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Receiver Repro Command: $ModuleBase\tools\CTS-Traffic\ctsTraffic.exe -listen:<ReceivingNicIP> -Protocol:tcp -buffer:262144 -transfer:21474836480 -Pattern:push -TimeLimit:30000" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Sender Repro Command: $ModuleBase\tools\CTS-Traffic\ctsTraffic.exe -target:<ReceivingNicIP> -bind:<SenderIP> -Connections:64 -Iterations:1 -Protocol:tcp -buffer:262144 -transfer:21474836480 -Pattern:push" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage2.PSObject.Properties.Name -contains "InterfaceFailures") {
                        "`nInterface Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "TCP throughput failed to meet threshold across all source NICs for the following target NICs:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage2.InterfaceFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC provisioning. Inspect VMQ, VMMQ, and RSS settings. Verify firewall settings for the erring machine. If the problem persists, consider checking NIC cabling or physical interlinks."  | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage2.PSObject.Properties.Name -contains "MachineFailures") {
                        "`nMachine Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "TCP throughput failed to meet threshold across all source machines for the following target machines:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage2.MachineFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC provisioning. Inspect VMQ, VMMQ, and RSS settings. If the problem persists, consider checking NIC cabling or physical interlinks."  | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                }
                'Stage3' {
                    if ($NetStackResults.Failures.Stage3.PSObject.Properties.Name -contains "IndividualFailures") {
                        "Individual Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Ping failed across the following connections:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage3.IndividualFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Retry NDK Ping with repro commands. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Receiver Repro Command: NdkPerfCmd.exe -S -ServerAddr <ReceivingNicIP>:9000  -ServerIf <ReceivingNicInterfaceIndex> -TestType rping -W 15 2>&1" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Sender Repro Command: NdkPerfCmd.exe -C -ServerAddr  <ReceivingNicIP>:9000 -ClientAddr <SendingNicIP> -ClientIf <SendingNicInterfaceIndex> -TestType rping 2>&1" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage3.PSObject.Properties.Name -contains "InterfaceFailures") {
                        "`nInterface Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Ping failed across all source NICs for the following target NICs:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage3.InterfaceFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC provisioning. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage3.PSObject.Properties.Name -contains "MachineFailures") {
                        "`nMachine Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Ping failed across all source machines for the following target machines:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage3.MachineFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC provisioning. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                }
                'Stage4' {
                    if ($NetStackResults.Failures.Stage4.PSObject.Properties.Name -contains "IndividualFailures") {
                        "Individual Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Perf (1:1) failed across the following connections:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage4.IndividualFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Retry NDK Perf (1:1) with repro commands. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Receiver Repro Command: NDKPerfCmd.exe -S -ServerAddr <ReceivingNicIP>:9000  -ServerIf <ReceivingNicInterfaceIndex> -TestType rperf -W 20 2>&1" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Sender Repro Command: NDKPerfCmd.exe -C -ServerAddr <ReceivingNicIP>:9000 -ClientAddr <SendingNicIP> -ClientIf <SendingNicInterfaceIndex> -TestType rperf 2>&1" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage4.PSObject.Properties.Name -contains "InterfaceFailures") {
                        "`nInterface Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Perf (1:1) failed across all source NICs for the following target NICs:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage4.InterfaceFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC RDMA provisioning and traffic class settings. Consider confirming NIC firmware and drivers, as well. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage4.PSObject.Properties.Name -contains "MachineFailures") {
                        "`nMachine Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Perf (1:1) failed across all source machines for the following target machines:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage4.MachineFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC RDMA provisioning and traffic class settings. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                }
                'Stage5' {
                    if ($NetStackResults.Failures.Stage5.PSObject.Properties.Name -contains "InterfaceFailures") {
                        "Interface Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Perf (N:1) failed for the following target NICs:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage5.InterfaceFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC RDMA provisioning and traffic class settings. Consider confirming NIC firmware and drivers, as well. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                    if ($NetStackResults.Failures.Stage5.PSObject.Properties.Name -contains "MachineFailures") {
                        "`nMachine Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Perf (N:1) failed across all source machines for the following target machines:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage5.MachineFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC RDMA provisioning and traffic class settings. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                }
                'Stage6' {
                    if ($NetStackResults.Failures.Stage6.PSObject.Properties.Name -contains "NetworkFailures") {
                        "Network Failure Recommendations" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "NDK Perf (N:N) failed for networks with the following subnet/VLAN:" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        $NetStackResults.Failures.Stage6.NetworkFailures | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                        "Verify NIC RDMA provisioning and traffic class settings. Consider confirming NIC firmware and drivers, as well. If the problem persists, consider checking NIC cabling or physical interlinks." | Out-File $LogFile -Append -Encoding utf8 -Width 2000
                    }
                }
                }
            "`n" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
        }
        "####################################`r`n" | Out-File $LogFile -Append -Encoding utf8 -Width 2000
    }
}

Function Get-NetworkATCAdapters {
    param (
        [string] $ClusterName
    )

    if (-not($ClusterName)) {
        try { $ClusterName = (Get-Cluster -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Name }
        catch { }
    }

    # try in case ATC commands are not available
    try {
        $NetIntents          = Get-NetIntent              -ClusterName $ClusterName -ErrorAction SilentlyContinue
        $NetIntentGoalStates = Get-NetIntentAllGoalStates -ClusterName $ClusterName -ErrorAction SilentlyContinue
    } catch { }

    $IntentData = @()
    Foreach ($intent in $NetIntents) {
        $thisIntentType = Convert-NetworkATCIntentType -IntentType $intent.IntentType

        $ATCManagementvNIC = $NetIntentGoalStates.${env:computername}.$($intent.IntentName).SwitchConfig.SwitchHostVNic
        $ATCStoragevNIC    = $NetIntentGoalStates.${env:computername}.$($intent.IntentName).SwitchConfig.StorageVirtualNetworkAdapters.PhysicalEndpointAdapterName
        $ATCStatus         = Get-NetIntentStatus -Name $intent.IntentName -ClusterName $ClusterName

        $thisIntent = [PSCustomObject] @{
            IntentName = $intent.IntentName
            Scope      = $intent.Scope
            Adapters   = $intent.NetAdapterNamesAsList
            IntentType = $thisIntentType
            ManagementvNIC = $ATCManagementvNIC
            StoragevNIC    = $ATCStoragevNIC
            LastConfigApplied = $ATCStatus.LastConfigApplied
            Progress          = $ATCStatus.Progress
        }

        $IntentData += $thisIntent
    }

    Return $IntentData
}
#endregion Helper Functions
