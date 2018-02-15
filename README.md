# NETWORK CONFIGURATION REPOSITORY

**cvs-netconfig** is a network management tool that automatically maintains
repository of network routers and switches configurations. It observes
syslog to figure out when configuration of a network device has changed and
then downloads the changed configuration and commits it into an [RCS](https://en.wikipedia.org/wiki/Revision_Control_System)
repository.  Any device reachable with ssh and static password is supported;
Cisco devices have extra level of support.

The resulting RCS repository can be browsed on a web server with [ViewVC](http://www.viewvc.org/) web application. This includes browsing through revisions and comparing revisions.

This tool was written for my employer, so it might be rough around the edges
at some places.  Please note, that the "CVS" in the name is a misnomer. 
There's no relation to actual CVS versioning system.

-----

## Requirements

* Perl 5.10 or newer
* Following perl modules: Expect, Cwd, JSON, Log::Log4Perl, File::Tail

-----

## File System Layout

    /opt/cvs            .. home directory of user cvs
        prod/           .. production directory
            bin/        .. executable scripts
            cfg/        .. configuration files
            data/       .. RCS repository
        dev/            .. development directory

I recommend to clone/update git repository into `dev` directory and copy the
files into `prod` directory.  The `/opt/cvs` prefix is configurable in the
`cvs-logwatcher.pl` script itself.

-----

## How It Works

The `cvs-logwatcher.pl` script opens and monitors one or more logs and
watches for preconfigured messages that indicate that router/switch
configuration has changed.  Example message from Cisco switch looks like
this:

    Aug 29 14:06:19.642 CEST: %SYS-5-CONFIG_I: Configured from console by rborelupo on vty0 (172.16.20.30)

Triggered by such a message, the script will download the device's
configuration, and check it into local RCS repository residing in `data`
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


## Configuration

Most of the program's behaviour is prescribed in configuration. The
configuration resides in the `cfg` directory. Following files are used:

    config.json  ... main configuration file
    keyring.json ... passwords used in configuration file
    logging.conf ... Log2Perl configuration

The JSON files use "relaxed" format, that allows comments and trailing commas.

### keyring.json

This file defines passwords/keys that can be used in the main config. This
makes it possible to share the config with third parties without divulging
sensitive information. The name of this file can be changed with `config.keyring`
(see below).

### config.json

The main configuration file is a JSON file. The configuration is designed to be highly flexible, which in turn means it is quite overwhelming at first. I encourage you to peruse the example configuration to see what it's all about.

#### Replacement tokens (placeholders)

In many parts of the configuration, following placeholders can be used:

`%d` becomes '-dev' if running in development mode, otherwise ''  
`%T` full tftp target directory  
`%t` tftp subdirectory relative to tftp root  
`%i` IP address local TFTP server is reachable on
`%h` device hostname as gleaned given in the monitored logfile  
`%H` same as %h but without domain  
`%P` prompt, this can be set within a chat script and used to match system prompt  

Additional tokens can be defined in _keyring.json_ file, these are meant to be used for passwords (so they don't appear directly in the configuration file).

In chat scripts (see below), the capture groups in the "expect" strings are accessible in the "response" strings as `%+0`, `%+1` etc.

#### General configuration

**`logprefix`**  
defines where the logfiles are stored, usual value is
`/var/log` on Unix-like systems. Specifying individual log files with relative
filenames will prepend this value to them.

**`src-ip`**  
defines the IP address that is to be used for sending configuration
to a TFTP server, so it should be the primary interface for the server the program runs on.

**`tftproot`**  
defines TFTP server root directory

**`tftpdir`**  
defines subdirectory within TFTP root where the configs will
be saved, even the ones not actually retrieved with TFTP; the scripts write access to this directory so that it can process and remove retrieved files

**`keyring`**  
defines the keyring file

**`tailint`**  
defines how often the logfiles are checked for new lines
(in seconds), this basically defines maximum reaction delay

**`tailmax`**  
defines how long (in seconds) will the program wait for
new lines to appear in a logfile; after this time the logfile will be closed
and reopened.

**`expmax`**  
defines the default expect timeout for interacting with
devices. If this timeout is exceeded, the attempt to talk to a device
is abandoned.

#### RCS configuration

**`rcsrepo`**  
defines the subdirectory that will hold the RCS repository

**`rcsctl`**, **`rcsci`**, **`rcsco`**  
defines the path to the RCS binaries

#### MIB configuration

**`writeNet`**  
defines OID of the writeNet SNMP variable, used for triggering
TFTP upload on Cisco IOS devices

**`hostName`**  
defines OID of the hostName SNMP variable, used for retrieving
devices canonical hostname

**`sysName`**  
defines OID of the sysName SNMP variable, used for retrieving
devices canonical hostname (backup for when hostName is unavailable)

**`sysDescr`**  
defines OID of the sysDescr SNMP variable, used to discriminate
specific Cisco devices platforms.

#### SNMP utilities configuration

**`get`**  
specifies path to SNMP get utility

**`set`**  
specifies path to SNMP set utility

#### Ping configuration

**`ping`**  
Defines command for testing device reachability -- unreachable devices are skipped to avoid lengthy timeouts.

#### Device groups configuration

**`groups`**  
defines device groups, that are used to store their config in separate
subdirectories in the repository. The key is a hash of group names that in turn
are arrays of regexes. For example:

    "groups" : {
       "routers" : [ "^router", "^bsc", "^cisco" ],
       "dcswitches" : [ "^dc.*s$", "^sw" ],
       "lanswitches" : [ "^lan" ],
    }

#### Ignored users configuration

**`ignoreusers`**  
is an array that lists users who should not trigger repository update

#### Logfiles configuration

This section lists logfiles that the program will observe for configuration
events. When the defined regex matches, the "Targets" list will be searched
for a match based on the log id and hostname. The first match is used and
terminates further search.

**`filename`**  
is either absolute or relative pathname; if it is relative, `config.logprefix` is prepended to it.

**`match`**  
specifies regular expression that when matched in
the logfile will trigger further processing. The regex *must* contain named
capture group `host` that matches source hostname; capture groups
`user` and `msg` are optional, but desirable.

#### Targets configuration

When a logfile match occurs, the program will search list of targets to decide
what actiion to perform. The targets are defined as list of hashes, that define number of various options. Options `logfile` and `hostmatch` are used when searching for
a matching target. The first matching target is used and the rest is skipped.

The reason for this logfile → target indirection is to enable to have one logfile
to trigger different actions if the user so desires. Currently the discrimination
is only hostname-based, but the mechanism could be extended later.

**`id`**  
Target identification name. Arbitrary string, but you should use something short
and mnemonic.

**`defgrp`**  
Default device group, this can be overriden through the device group
configuration mentioned above.

**`logfile`**  
Defines log id as defined in the `logfiles` section. This key is *required* and it is used for matching logfile matches to targets.

**`hostmatch`**  
Optional. Enables additional matching by device's hostname (in addition to matching by `logfile`!). Hostmatch is a
list of rules, where every rule can have one to four matching conditions: `includelist` and `excludelist` exactly (but case-insensitively) match lists of hostnames. `includere` and `excludere` match hostnames by one or more regular expressions. For example:

    {
      "includelist" : [ "router01", "router02", "switch01" ]
    }
 
This will simply match the three devices in the list.
 
    {
      "excludelist" : [ "router01", "router02" ],
    }

This rule will match anything but the two devices in the list.

    {
      "includelist" : [ "router01", "router02", "switch01" ],
      "excludelist" : [ "router01", "router02" ],
    }

You can combine the two filters into one rule -- both must match at the same time. That means, that in above example router00 and router01 will not be matched by this (the results of the two matches are AND'ed together, so router01 will pass the `includelist`, but not the `excludelist`. The switch01 will be matched just fine, however.

    {
      "includere" : [ "^router-" ],
      "excludere" : [ "^router-wy-", "^router-ak-" ],
    }

Matching by regular expressions is also available and has the same semantics as the `lst` matches. Above example will match all devices that start with "router-" except those that start with "router-wy-" and "router-ak-".

    {
      "excludere" : [ "^sw-(london|paris)" ],
    },
    {
      "includelst" : [ "sw-london-01", "sw-paris-01" ],
    }

Multiple rules can be specified in a `hostmatch` (make it a "ruleset"), though this is probably not very useful. At any rate, ruleset is considered a match when at least one rule is a match. In above example any device that doesn't start with "sw-london" or "sw-paris" is matched, but "sw-london-01" and 'sw-london-01" are exempt from this exclusion and are matched anyway.

**`snmp.ro`**, **`snmp.ver`**  
Define read-only community and SNMP version.

**`options`**  
Define list of options that should be used for the target. Following options are supported:

* `snmphost` this will cause the program to perform SNMP query for system name; if such query succeeds, the obtained name is used for the device instead of that from logfile; this makes it possible to have properly capitalized device names
* `normeol` this option will make the program to convert retrieved configurations to local end-of-line characters; this is recommended
* `cisco-writenet` this option will make the program retrieve configuration from the device by issuing a SNMP set to `mib.writeNet` OID; this compels the device to initiate a TFTP upload

**`validate`**  
This specifies list of regular expressions that each must match at least once per configuration file. This can be used to defend against failed downloads. Try to use something that is guaranteed to appear at the end of the configuration. For example Cisco IOS configuration always has `end` as the last line, Nokia 7750SR has final line that starts with `# Finished`, etc. This is highly recommended.

**`validrange`**  
This specifies exactly two regular expressions that define the first and last line of the configuration. The lines outside of this range are discarded. This allows one to get rid of the junk that is caused by recording the whole session with the device.

For example, this works for Cisco IOS:

    "validrange" : [ "^(!|version )", "^end\\s*$" ],

**`filter`**  
List of regular expressions, all matching lines are discarded from the configuration. This is a complement to the `validrange` option.

**`ignoreline`**  
Defines single regular expression that specifies configuration lines that should be ignored when comparing new and old revision of the config. This lets the program ignore certain parts of the configuration that change even when the config actually doesn't (comments, Cisco IOS's `ntp clock-period` etc.)

**`expect.spawn`**  
Command to be executed to initiate a session with the device. Example for SSH:

    "spawn" : "/usr/bin/ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l cvs1 %h"

Note, that `%h` is expanded into hostname. Few more replacement tokens is supported, see elsewhere in this documentation.

**`expect.sleep`**  
Number of seconds to pause between individual commands for the device.

**`expect.chat`** 
This defines a *chat script*, that will be followed while communicating with the device. Normally the chat is used to log into device and issue a command to list device's configuration, which is recorded and used for the repository. Each line in the chat is an array of at most four items:

    [ EXPECT-STRING, SEND-STRING, OUTPUT-LOG, PROMPT ]

_Expect string_ is regular expression that the program tries to match in the output from the device. It may contain capture groups (only regular capture groups, named caputre groups are not supported, unfortunately). Capture groups are made available to the send strings as `%+0`, `%+1` etc, but note that they do not carry over to the next line of the chat script.

_Send string_ is simply a string that is sent to the device when the expect string is matched. Replacement tokens can be used, use `\r` to send end-of-line.

_Output log_ is optional. When specified, the output from the device is saved into given filename. This is how the configuration files are retrieved.

_Prompt_ is optional. When it is specified, the contents of the string is stored into special token `%P`. This is useful for establishing device's prompt that you can use in further matches.

Now let's see how this all comes together -- following script works with Cisco IOS/IOS XR/NX-OS devices:

    "chat" : [
      [ "(Password|PASSWORD|password):", "%3\r" ],
      [ "^(\\S*)#", "term len 0\r", null, "%+0" ],
      [ "^%P#", "sh run\r", "%T/%H" ],
      [ "^%P#", "exit\r" ],
    ],

The _first line_ waits for password prompt and sends the password (which here is represented by the token %3, which is defined in external file through the `keyring` feature).

The _second line_ waits for the prompt, which is identified as having `#` in it. The regex has capture group that is used in the fourth item to set up the `%P` prompt "variable". When the prompt is seen, output pagination is disabled.

The _third line_ waits for the prompt, now identified in its entirety (matching only `#` can lead to false matches that would truncate the config output) and command to display the configuration is issued and recorded into a file. The file's location is again specified using % tokens: `%T` is directory and `%H` is hostname.

The _fourth line_ then waits for another prompt and finishes the session with a logout.

## Command-line Options

**`--help`**  
Display command-line options summary.

**`--trigger=LOGID`**  
Manually trigger event with source LOGID as defined in the `logfiles` configuration section. You must provide at least the source hostname using the `--host` option.

**`--host=HOST`**  
Provides source hostname of a manually triggered event.

**`--user=USER`**  
Provides username for a manually triggered event. Can be omitted, in that case `unknown` is used instead.

**`--msg=MESSAGE`**  
Provides commit message for a manually triggered event.

**`--force`**  
Force RCS commit even when there's no change in the configuration (after filtering using the `ignoreline` target option). Note that when old and new revision are *exactly* the same, no commit is created by RCS.

**`--snmp-name`**  
Query device given with the `--host` option for system name and then quit.

**`--nocheckin[=PATHNAME]`**  
Do not perform RCS check in after successfully retrieving configuration from a device. When no PATHNAME is defined, the file is just left in the directory it was downloaded to. When directory is specified, the file is moved there. When filename is specified, the file is renamed into it. This should only be used when manually triggering with the `--trigger` option.

**`--nomangle`**  
Do not perform configuration file transformations prescribed in the target config.

## To Do

* Fork the processing part. At this moment the processing blocks the entire program, which means that it's quite unsuitable for high traffic uses.
* Implement "automatic refresh" -- this feature would on regular basis try to refresh devices with too old configs in repository. This would probably necessitate some kind of hostname storage so that the program know where to go to for the refresh.
