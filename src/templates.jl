templates_folder() = joinpath(homedir(), ".azmanagers")

function save_template(templates_filename::AbstractString, name::AbstractString, template::Dict)
    templates = isfile(templates_filename) ? JSON.parse(read(templates_filename, String)) : Dict{String,Any}()
    templates[name] = template
    if !ispath(templates_folder())
        mkdir(templates_folder())
    end
    write(templates_filename, json(templates, 1))
    nothing
end

#
# scale-set templates
#
"""
    AzManagers.build_sstemplate(name; kwargs...)

returns a dictionary that is an Azure scaleset template for use in `addprocs` or for saving
to the `~/.azmanagers` folder.

# required key-word arguments
* `subscriptionid` Azure subscription
* `admin_username` ssh user for the scaleset virtual machines
* `location` Azure data-center location
* `resourcegroup` Azure resource-group
* `imagegallery` Azure image gallery that contains the VM image
* `imagename` Azure image
* `vnet` Azure virtual network for the scaleset
* `subnet` Azure virtual subnet for the scaleset
* `skuname` Azure VM type

# optional key-word arguments
* `subscriptionid_image` Azure subscription corresponding to the image gallery, defaults to `subscriptionid`
* `resourcegroup_vnet` Azure resource group corresponding to the virtual network, defaults to `resourcegroup`
* `resourcegroup_image` Azure resource group correcsponding to the image gallery, defaults to `resourcegroup`
* `osdisksize=60` Disk size in GB for the operating system disk
* `skutier = "Standard"` Azure SKU tier.
* `datadisks=[]` list of data disks to create and attach [1]
* `tempdisk = "sudo mkdir -m 777 /mnt/scratch\nln -s /mnt/scratch /scratch"` cloud-init commands used to mount or link to temporary disk

# Notes
[1] Each datadisk is a Dictionary. For example,
```julia
Dict("createOption"=>"Empty", "diskSizeGB"=>1023, "managedDisk"=>Dict("storageAccountType"=>"PremiumSSD_LRS"))
```
or, to accept the defaults,
```julia
Dict("diskSizeGB"=>1023)
```
The above example is populated with the default options.  So, if `datadisks=[Dict()]`, then the default options
will be included.
"""
function build_sstemplate(name;
        subscriptionid,
        subscriptionid_image = "",
        admin_username,
        location,
        resourcegroup,
        resourcegroup_vnet = "",
        resourcegroup_image = "",
        imagegallery,
        imagename,
        vnet,
        subnet,
        skutier="Standard",
        osdisksize=60,
        datadisks=[],
        tempdisk="sudo mkdir -m 777 /mnt/scratch\nln -s /mnt/scratch /scratch",
        skuname)
    resourcegroup_vnet == "" && (resourcegroup_vnet = resourcegroup)
    resourcegroup_image == "" && (resourcegroup_image = resourcegroup)
    subscriptionid_image == "" && (subscriptionid_image = subscriptionid)
    subnetid = "/subscriptions/$subscriptionid/resourceGroups/$resourcegroup_vnet/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/$subnet"
    image = "/subscriptions/$subscriptionid_image/resourceGroups/$resourcegroup_image/providers/Microsoft.Compute/galleries/$imagegallery/images/$imagename"

    _datadisks = Dict{String,Any}[]
    ultrassdenabled = false
    for (idisk,datadisk) in enumerate(datadisks)
        datadisk_template = Dict{String,Any}("createOption"=>"Empty", "diskSizeGB"=>1023, "lun"=>1, "managedDisk"=>Dict("storageAccountType"=>"Premium_LRS"))
        merge!(datadisk_template, datadisk)
        merge!(datadisk_template, Dict("lun"=>idisk))
        push!(_datadisks, datadisk_template)
        if datadisk_template["managedDisk"]["storageAccountType"] ∈ ("UltraSSD_LRS",)
            ultrassdenabled = true
        end
    end

    Dict(
        "tempdisk" => tempdisk,
        "value" => Dict(
            "sku" => Dict(
                "tier" => skutier,
                "capacity" => 2,
                "name" => skuname
            ),
            "location" => location,
            "properties" => Dict(
                "overprovision" => true,
                "singlePlacementGroup" => false,
                "additionalCapabilities" => Dict(
                    "ultraSSDEnabled" => ultrassdenabled
                ),
                "virtualMachineProfile" => Dict{String,Any}(
                    "storageProfile" => Dict(
                        "imageReference" => Dict(
                            "id" => image
                        ),
                        "osDisk" => Dict(
                            "caching" => "ReadWrite",
                            "managedDisk" => Dict(
                                "storageAccountType" => "Standard_LRS"
                            ),
                            "createOption" => "FromImage",
                            "diskSizeGB" => osdisksize
                        ),
                        "dataDisks" => _datadisks
                    ),
                    "osProfile" => Dict(
                        "computerNamePrefix" => replace(name, "+"=>"plus"),
                        "adminUsername" => admin_username,
                        "linuxConfiguration" => Dict(
                            "ssh" => Dict(
                                "publicKeys" => []
                                ),
                            "disablePasswordAuthentication" => true
                        )
                    ),
                    "networkProfile" => Dict(
                        "networkInterfaceConfigurations" => [
                            Dict(
                                "name" => replace(name, "+"=>"plus"),
                                "properties" => Dict(
                                    "primary" => true,
                                    "ipConfigurations" => [
                                        Dict(
                                            "name" => replace(name, "+"=>"plus"),
                                            "properties" => Dict(
                                                "subnet" => Dict(
                                                    "id" => subnetid
                                                )
                                            )
                                        )
                                    ] # ipConfigurations
                                )
                            )
                        ] # networkInterfaceConfigurations
                    ), # networkProfile
                ), # virtualMachineProfile
                "upgradePolicy" => Dict(
                    "mode" => "Manual"
                )
            ) # properties
        )
    )
end

templates_filename_scaleset() = joinpath(templates_folder(), "templates_scaleset.json")

"""
    AzManagers.save_template_scaleset(scalesetname, template)

Save `template::Dict` generated by AzManagers.build_sstemplate to $(templates_filename_scaleset()).
"""
save_template_scaleset(name::AbstractString, template::Dict) = save_template(templates_filename_scaleset(), name, template)

#
# NIC templates
#
"""
    AzManagers.build_nictemplate(nic_name; kwargs...)

Returns a dictionary for a NIC template, and that can be passed to the `addproc` method, or written
to AzManagers.jl configuration files.

# Required keyword arguments
* `subscriptionid` Azure subscription
* `resourcegroup_vnet` Azure resource group that holds the virtual network that the NIC is attaching to.
* `vnet` Azure virtual network for the NIC to attach to.
* `subnet` Azure sub-network name.
* `location` location of the Azure data center where the NIC correspond to.

# Optional keyword arguments
* `accelerated=true` use accelerated networking (not all VM sizes support accelerated networking).
"""
function build_nictemplate(name;
        subscriptionid,
        resourcegroup_vnet,
        vnet,
        subnet,
        accelerated = true,
        location)
    subnetid = "/subscriptions/$subscriptionid/resourceGroups/$resourcegroup_vnet/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/$subnet"

    body = Dict(
        "properties" => Dict(
            "enableAcceleratedNetworking" => accelerated,
            "ipConfigurations" => [
                Dict(
                    "name" => "ipConfig1",
                    "properties" => Dict(
                        "subnet" => Dict(
                            "id" => subnetid
                        )
                    )
                )
            ]
        ),
        "location" => location
    )
end

templates_filename_nic() = joinpath(templates_folder(), "templates_nic.json")

"""
    AzManagers.save_template_nic(nic_name, template)

Save `template::Dict` generated by AzManagers.build_nictmplate to $(templates_filename_nic()).
"""
save_template_nic(name::AbstractString, template::Dict) = save_template(templates_filename_nic(), name, template)

#
# VM templates
#
"""
    AzManagers.build_vmtemplate(vm_name; kwargs...)

Returns a dictionary for a virtual machine template, and that can be passed to the `addproc` method
or written to AzManagers.jl configuration files.

# Required keyword arguments
* `subscriptionid` Azure subscription
* `admin_username` ssh user for the scaleset virtual machines
* `location` Azure data center location
* `resourcegroup` Azure resource group where the VM will reside
* `imagegallery` Azure shared image gallery name
* `imagename` Azure image name that is in the shared image gallery 
* `vmsize` Azure vm type, e.g. "Standard_D8s_v3"

# Optional keyword arguments
* `resourcegroup_vnet` Azure resource group containing the virtual network, defaults to `resourcegroup`
* `subscriptionid_image` Azure subscription containing the image gallery, defaults to `subscriptionid`
* `resourcegroup_image` Azure resource group containing the image gallery, defaults to `subscriptionid`
* `nicname = "cbox-nic"` Name of the NIC for this VM
* `osdisksize = 60` size in GB of the OS disk
* `datadisks=[]` additional data disks to attach
* `tempdisk = "sudo mkdir -m 777 /mnt/scratch\nln -s /mnt/scratch /scratch"`  cloud-init commands used to mount or link to temporary disk

# Notes
[1] Each datadisk is a Dictionary. For example,
```julia
Dict("createOption"=>"Empty", "diskSizeGB"=>1023, "managedDisk"=>Dict("storageAccountType"=>"PremiumSSD_LRS"))
```
The above example is populated with the default options.  So, if `datadisks=[Dict()]`, then the default options
will be included.
"""
function build_vmtemplate(name;
        subscriptionid,
        admin_username,
        subscriptionid_image = "",
        location,
        resourcegroup,
        resourcegroup_vnet = "",
        resourcegroup_image = "",
        imagegallery,
        imagename,
        vmsize,
        osdisksize = 60,
        datadisks = [],
        tempdisk = "sudo mkdir -m 777 /mnt/scratch\nln -s /mnt/scratch /scratch",
        nicname = "cbox-nic")
    resourcegroup_vnet == "" && (resourcegroup_vnet = resourcegroup)
    resourcegroup_image == "" && (resourcegroup_image = resourcegroup)
    subscriptionid_image == "" && (subscriptionid_image = subscriptionid)

    image = "/subscriptions/$subscriptionid_image/resourceGroups/$resourcegroup_image/providers/Microsoft.Compute/galleries/$imagegallery/images/$imagename"

    ultrassdenabled = false
    _datadisks = Dict{String,Any}[]
    for (idisk,datadisk) in enumerate(datadisks)
        datadisk_template = Dict{String,Any}("createOption"=>"Empty", "diskSizeGB"=>1023, "lun"=>1, "managedDisk"=>Dict("storageAccountType"=>"Premium_LRS"))
        merge!(datadisk_template, datadisk)
        merge!(datadisk_template, Dict("lun"=>idisk, "name"=>"scratch$idisk"))
        push!(_datadisks, datadisk_template)
        if datadisk_template["managedDisk"]["storageAccountType"] ∈ ("UltraSSD_LRS",)
            ultrassdenabled = true
        end
    end

    Dict(
        "tempdisk" => tempdisk,
        "value" => Dict(
            "location" => location,
            "properties" => Dict(
                "additionalCapabilities" => Dict(
                    "ultraSSDEnabled"=>ultrassdenabled
                ),
                "hardwareProfile" => Dict(
                    "vmSize" => vmsize
                ),
                "storageProfile" => Dict(
                    "imageReference" => Dict(
                        "id" => image
                    ),
                    "osDisk" => Dict(
                        "caching" => "ReadWrite",
                        "managedDisk" => Dict(
                            "storageAccountType" => "Standard_LRS"
                        ),
                        "createOption" => "FromImage",
                        "diskSizeGB" => osdisksize
                    ),
                    "dataDisks" => _datadisks
                ),
                "osProfile" => Dict(
                    "computerName" => name,
                    "adminUsername" => admin_username,
                    "linuxConfiguration" => Dict(
                        "ssh" => Dict(
                            "publicKeys" => []
                        ),
                        "disablePasswordAuthentication" => true
                    )
                ),
                "networkProfile" => Dict(
                    "networkInterfaces" => [
                        Dict(
                            "id" => "/subscription/$subscriptionid/resourceGroups/$resourcegroup_vnet/providers/Microsoft.Network/networkInterfaces/$nicname",
                            "properties" => Dict(
                                "primary" => true
                            )
                        )
                    ]
                )
            )
        )
    )
end

templates_filename_vm() = joinpath(templates_folder(), "templates_vm.json")

"""
    AzManagers.save_template_vm(vm_name, template)

Save `template::Dict` generated by AzManagers.build_vmtmplate to $(templates_filename_vm()).
"""
save_template_vm(name::AbstractString, template::Dict) = save_template(templates_filename_vm(), name, template)
