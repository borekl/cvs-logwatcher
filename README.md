# NETWORK CONFIGURATION REPOSITORY

**cvs-netconfig** is a network management tool that automatically maintains
repository of network routers and switches configurations. It observes
syslog to figure out when configuration of a network device has changed and
then downloads the changed configuration and commits it into an RCS
repository.  Any device reachable with ssh and static password is supported;
Cisco devices have extra level of support.

This tool was written for my employer, so it might be rough around the edges
at some places.  Please note, that the "CVS" in the name is a misnomer. 
There's no relation to actual CVS versioning system.

-----

## Requirements

* Perl 5.10 or newer
* Expect module
* Cwd module
* JSON module
* Log::Log4Perl module
* File::Tail module 

-----

## File System Layout

    /opt/cvs            .. home directory of user cvs
        prod/           .. production directory
            bin/        .. executable scripts
            cfg/        .. configuration files
            data/       .. RCS repository
        dev/            .. development directory

I recommned to clone/update git repository into `dev` directory and copy the
files into `prod` directory.  The `/opt/cvs` prefix is configurable in the
`cvs-logwatcher.pl` script itself.

-----

## How Does It Work

The `cvs-logwatcher.pl` script opens and monitors one or more logs and
watches for preconfigured messages that indicate that router/switch
configuration has changed.  Example message from Cisco switch looks like
this:

    Aug 29 14:06:19.642 CEST: %SYS-5-CONFIG_I: Configured from console by rborelupo on vty0 (172.16.20.30)

Triggered by such a message, the script will download the device's
configuration, and check it into local repository residing in `data`
directory.

Configuration download can be performed in three ways:

* Cisco routers/switches can be triggered to upload configuration over tftp
by an SNMP set

* The script can log into the device and issue the upload command, that will
store it somewhere on the local server

* The script can log into the device and list the configuration within the
logon session and record it itself.

Once the local file is available, it is checked into the local repository
using RCS's `ci` command.

