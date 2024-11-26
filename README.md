# NETWORK CONFIGURATION REPOSITORY

**cvs-netconfig** is a network management tool that automatically maintains
repository of network routers and switches configurations. It observes
syslog to figure out when configuration of a network device has changed and
then downloads the changed configuration and commits it into
an [RCS](https://en.wikipedia.org/wiki/Revision_Control_System)
repository. Talking to nework devices is typically done with SSH,
but the configuration is flexible enough to support other methods such
as direct SCP fetches.

The resulting RCS repository can be browsed on a web server with
[ViewVC](http://www.viewvc.org/) or [CVSweb](https://help.ubuntu.com/community/CVSweb)
web applications. This includes browsing through revisions and comparing revisions.

This tool was written for my employer, so it might be rough around the edges
at some places. Please not, that while there's CVS in the name of the application,
it actually only uses basic RCS operations on single files, so there is no
need to have actual CVS installed. If you want web access with CVSweb or newer
ViewVC versions, you need to simulate CVS repository for these tools to work.
Generally it is enough to create a CVSROOT symlink in repository base directory
that points to the directory itself (ie. CVSROOT -> .)

-----

## Requirements

* Perl 5.12 or newer
* Following perl modules:
  * Expect
  * Log::Log4Perl
  * IO::Async
  * Moo
  * Feature::Compat::Try
  * Path::Tiny


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

* The script can log into the device and issue the upload command, that will
store it somewhere on the local server

* The script can log into the device and list the configuration within the
logon session and record it itself.

* The script can issue local command, such as scp or wget, that will fetch
the remote configuration

Once the local file is available, it is checked into the local repository
using RCS's `ci` command.


## Configuration

Most of the program's behaviour is prescribed in configuration. The
configuration resides in the `cfg` directory. Following files are used:

    config.cfg   ... main configuration file (perl syntax)
    keyring.cfg  ... passwords used in configuration file (perl syntax)
    logging.conf ... Log2Perl configuration

### keyring.cfg

This file defines passwords/keys that can be used in the main config. This
makes it possible to share the config with third parties without divulging
sensitive information. The name of this file can be changed with `config.keyring`
(see below).

### config.cfg

The main configuration file is a perl file. The configuration is designed to be highly flexible, which in turn means it is quite overwhelming at first. I encourage you to peruse the example configuration to see what it's all about.

#### Replacement tokens (placeholders)

In many parts of the configuration, following placeholders can be used:

`%D` temporary directory for retrieved configurations
`%h` device hostname as given in the monitored logfile
`%H` same as `%h` but without domain
`%P` prompt, this can be set within a chat script and used to match system prompt

Additional tokens can be defined in _keyring.cfg_ file, these are meant to be used for passwords (so they don't appear directly in the configuration file).

In chat scripts (see below), the capture groups in the "expect" strings are accessible in the "response" strings as `%+0`, `%+1` etc.

#### General configuration

    config => {
      logprefix => '/var/log',
      tempdir => 'temp',
      keyring => 'keyring.cfg',
      expmax => 120,
    }

**`logprefix`**
defines where the logfiles are stored, usual value is
`/var/log` on Unix-like systems. Specifying individual log files with relative
filenames will prepend this value to them.

**`tempdir`**
defines temporary directory that is used to store configurations received from devices

**`keyring`**
defines the keyring file

**`expmax`**
defines the default expect timeout for interacting with
devices. If this timeout is exceeded, the attempt to talk to a device
is abandoned.

#### RCS configuration

    rcs => {
      rcsrepo => 'data',
      rcsctl => '/usr/bin/rcs',
      rcsci => '/usr/bin/ci',
      rcsco => '/usr/bin/co',
    }

**`rcsrepo`**
defines the subdirectory that will hold the RCS repository files

**`rcsctl`**, **`rcsci`**, **`rcsco`**
defines the path to the RCS binaries

#### Ping configuration

    ping => 'ping -c 1 -W 2 %h >/dev/null 2>&1',

**`ping`**
Defines command for testing device reachability -- unreachable devices are skipped to avoid lengthy timeouts.

#### Device groups configuration

**`groups`**
defines device groups, that are used to store their config in separate
subdirectories in the main repository directory. The key is a hash of group
names that in turn are arrays of regexes used match hostnames. For example:

    groups => {
       routers => [ '^router', '^bsc', '^cisco' ],
       dcswitches => [ '^dc.*s$', '^sw' ],
       lanswitches => [ '^lan' ],
    }

#### Ignored users and hosts configuration

**`ignoreusers`**
is an array that lists users who should not trigger repository update

#### Logfiles configuration

This section defines logfiles that the program will observer for configuration
events. Each log has a user defined LOGID, which can be referenced by some
of the command-line options. The general format is as follows:

    logfiles => {
      LOGID1 => { log configuration ... },
      LOGID2 => { log configuration ... },
      ...
    }

Each log is configured with a hash that contains two keys `filename` and `match`.
The `filename` should be fairly self-explanatory and defines the log to open
and observe as either absolute or relative pathname. If it is relative,
`config.logprefix` is prepended to it. The `match` key defines one or more
regular expressions which the program matches against every new line received
from the log. Each regex has its own MATCHID, which again is used to reference
it later. The general format is as follows:

    LOGID => {
      filename => '/var/log/somefile.log',
      match => {
        MATCHID1 => 'regex1',
        MATCHID2 => 'regex2',
        ...
      }
    }

The regular expression must define at least named capture group `host`.
Capture groups `user` and `msg` are optional.

After a match, the matched log line is thus associated with LOGID, MATCHID
and a host. These values are used to select a _target_, which defines
the action that should be performed.

Example log configuration for a CISCO IOS network device with only one
MATCHID:

    logfiles => {
      cisco => {
        filename => '/var/log/cisco/cisco.log',
        match => {
           cisco => '^.*\s+\d+\s+[0-9:]+\s+(?<host>[\w\d.]+)\s+.*CONFIG_I.*(?<msg>Configured from (?:console|vty) by (?<user>\w+).*)\s*$',
        }
      }
    }

#### Targets configuration

When a logfile match occurs, the program will search list of targets to decide
which one will be used to determine what to do. Target configuration prescribes
the interaction with given device. One log matching rule might end up in
different targets to accommodate different device configurations, operating
systems, etc.  The targets are defined as list of hashes, that define number of
various options. Keys `matchid` and `hostmatch` are used when searching for
a matching target. The first matching target is used and the rest is ignored.

**`id`**
Target identification name. Arbitrary string, but you should use something short
and mnemonic, this is what will appear in the logs.

**`defgrp`**
Default device group, this can be overriden through the device group
configuration mentioned above. Groups are used to separate the configs into
directories.

**`matchid`**
Defines MATCHID as defined in the `logfiles` section. This key is *required* and
it is used for matching logfile matches to targets. Multiple targets can use the
same MATCHID.

**`hostmatch`**
Optional. Enables additional matching by device's hostname (in addition to
matching by `logfile`!). Hostmatch is a list of rules, where every rule can have
one to four matching conditions: `includelist` and `excludelist` exactly (but
case-insensitively) match lists of hostnames. `includere` and `excludere` match
hostnames by one or more regular expressions. For example:

    {
      includelist => [ 'router01', 'router02', 'switch01' ]
    }

This will simply match the three devices in the list.

    {
      excludelist => [ 'router01', 'router02' ],
    }

This rule will match anything but the two devices in the list.

    {
      includelist => [ 'router01', 'router02', 'switch01' ],
      excludelist => [ 'router01', 'router02' ],
    }

You can combine the two filters into one rule -- both must match at the same
time. That means, that in above example router00 and router01 will not be
matched by this (the results of the two matches are AND'ed together, so router01
will pass the `includelist`, but not the `excludelist`. The switch01 will be
matched just fine, however.

    {
      includere => [ '^router-' ],
      excludere => [ '^router-wy-', '^router-ak-' ],
    }

Matching by regular expressions is also available and has the same semantics as
the `lst` matches. Above example will match all devices that start with
"router-" except those that start with "router-wy-" and "router-ak-".

    {
      excludere => [ '^sw-(london|paris)' ],
    },
    {
      includelst => [ 'sw-london-01', 'sw-paris-01' ],
    }

Multiple rules can be specified in a `hostmatch` (make it a "ruleset"), though
this is probably not very useful. At any rate, ruleset is considered a match
when at least one rule is a match. In above example any device that doesn't
start with "sw-london" or "sw-paris" is matched, but "sw-london-01" and
'sw-london-01" are exempt from this exclusion and are matched anyway.

**`options`**
Define list of options that should be used for the target. Currently only one
option is supported:

* `normeol` this option will make the program to convert retrieved
  configurations to local end-of-line characters; this is recommended

**`validate`**
This specifies list of regular expressions that each must match at least once
per configuration file. This can be used to reject failed or corrupted
downloads. Try to use something that is guaranteed to appear at the end of the
configuration. For example Cisco IOS configuration always has `end` as the last
line, Nokia 7750SR has final line that starts with `# Finished`, etc. This is
highly recommended.

**`validrange`**
This specifies exactly two regular expressions that define the first and last
line of the configuration. The lines outside of this range are discarded. This
allows one to get rid of the junk that is caused by recording the whole session
with the device.

For example, this works for Cisco IOS:

    validrange => [ '^(!|version )', '^end\\s*$' ],

**`filter`**
List of regular expressions, all matching lines are discarded from the
configuration. This complements the `validrange` option.

**`ignoreline`**
Defines single regular expression that specifies configuration lines that should
be ignored when comparing new and old revision of the config. This lets the
program ignore certain parts of the configuration that change even when the
config actually doesn't (comments with timestamps, Cisco IOS's `ntp
clock-period` etc.)

**`hostname`**
Regular expression that tries to extract hostname as defined in the
configuration. This is useful when you do not want to rely on hostnames as
they appear in syslog (usually taken from DNS). The regex must have single
capturing group that is taken as containing the hostname. Cisco devices
example given below. Note how the first pattern group is made non-capturing with
(?:...) to not interfere with the actual group we are trying to capture and
which must be the first one.

    hostname => '^(?:hostname|switchname)\\s([-a-zA-Z0-9]+)',

**`files`**
Add files that are expected to be received from the remote device. This is
needed when the configuration is sent using utility such as scp or wget. Do not
specify this if you are receiving configuation by means of recording the expect
session.

**`action`**
This specifies anonymous in-line function (in perl), that is executed when the
target is invoked. The function receives two arguments: 1: stash instance, 2:
hash of named capture groups from the matching regular expression. This lets us
store some captured information into the "stash" for later use. This is useful
when the log entry that triggers retrieving configuration doesn't contain all
desired information to create the repository commit.

    action => sub {
      my ($stash, $data) = @_;
      my $idx = $data->{index};
      $stash->{$idx}{user} = $data->{user};
      $stash->{$idx}{comment} = $data->{comment};
    },

The example above expects to get named capture groups `index`, `user` and
`comment` from the regular expression match and it moves them into the stash.


**`commit`**
This is the output end of the logic pipeline fed by `action` option. This option
can specify two suboptions `msg` and `user`. Both are callbacks to a perl
function which receives stash instance and data from named capture group from
current log entry match. Both of the callbacks are expected to return a string
which is then used for commit message and commit user respectively.

    commit => {
      msg => sub {
        my ($stash, $data) = @_;
        my $idx = $data->{index};
        sprintf(
          'Commited by %s (comment: %s)',
          $stash->{$idx}{user}, $stash->{$idx}{comment}
        );
      },
    },

The above example retrieves information stored in the previous example for
`action`. It creates a commit message using the values of `comment` and `user`
that existed when the previous log entry was matched and which are not present
in the current log entry used for triggering the configuration backup.

**`expect`**
This is the most complex option in the *targets* section. It describes
interaction with the remote device by means of a chat script, ie. list of
expect-response pairs. Typically, a chat script will initiate connection to the
remote machine using SSH or invoke local utility to do the config retrieval,
such as SCP. The entire dialog with the remote machine can be broken into small
fragments (which we call *chats*), which are then sequenced into *tasks*.

Following options go into the `expect` subsection:

**`spawn`**
Command to be executed to initiate a session with the device. Example for SSH
with disabled host key checking, the %h token is replaced with hostname as it is
seen in the log (which means it must be something that SSH can connect to):

    spawn => '/usr/bin/ssh -l cvs1 %h'

When using SCP or other utility to retrieve the configuration directly, you have
to specify local file with %D and %H placeholders. Example for JunOS devices
might look like this:

    spawn => '/usr/bin/scp cvs1@%h:/config/juniper.conf %D/%H',

Note, that SSH/SCP, when connecting to a remote machine for the first time,
requires you to interactively verify its host key. This means that you either
need to retrieve the host key before first configuration backup or you need to
disable host key checking.

**`sleep`**
Number of seconds to pause between individual commands for the device; this may
be float.

**`chats`**

    chats => {
      login: [
        [ '(Password|PASSWORD|password):', '%3\r' ],
        [ '^\\s?(\\S*)#', 'term len 0\r', null, '%+0' ],
      ],
      getconfig => [
        [ '^\\s?%P#', 'sh run\r', '%D/%H' ],
        [ '^\\s?%P#', 'sh run\r', '-' ],
      ],
      getconfigall => [
        [ '^\\s?%P#', 'sh run all\r', '%D/%H.all' ],
        [ '^\\s?%P#', 'sh run\r', '-' ],
      ],
      logout => [
        [ '^\\s?%P#', 'exit\r' ],
      ],
    },

The `chats` section defines conversation with the device. They work by
specifying expected string and response, that is sent when the expected string
is seen. To make things slightly modular, the complete conversations are split
into smaller logical sections. In our example there `login` which defines how to
login into a device and set up the terminal. `getconfig` makes the device list
its config while recording this into a file, `getconfigall` does the same but
uses command to output config with defaults and finally `logout` defines how to
log out of the host. These conversation pieces are put together in the next
section called `tasks`

Individual lines of the conversations have the following form:

    [ EXPECT-STRING, SEND-STRING, OUTPUT-LOG, PROMPT ]

The first two fields are fairly obvious: the first one is a regex to match the
expected input from the device. The regex can use capturing groups which are
available to further conversation entries as %+0, %+1 etc. When the expect regex
is matched, contents of the second field is sent to the device

The third field is used to start recording the conversation into a file, so it
should specify a filename with path (relative to the `tempdir`. This is the
filename that will be presented to the RCS repository, so it must be unique to
the host and therefore contain "%h" or, better "%H" tokens. In the example above
we use the simplest filename of "%D/%H" for the plain config and "%D/$H.all" for
the full config. If this field contains "-", it will stop recording this log.
You should always explicitly stop recording, otherwise you will run into issues
(esp. when recording multiple files)

The fourth field allows setting the prompt token %P, which in further
conversation can be used to match device prompt. This is needed to make the
expect string specific enough to be useful (just matching "#" or ">" will
probably not work). This entry is used in the `login` chat above and it uses
capturing group in the expect string to set prompt %P for further entries:

    [ "^\\s?(\\S*)#", "term len 0\r", null, "%+0" ]

Further entries then use "^\\s?%P#" to match the real full prompt of the device.

**`tasks`**
Tasks are sequences of individual chatsdefined it `chats` section. They assemble
the complete dialogs to be used while talking to remote devices. For example
example:

    tasks => {
      config => {
        seq => [ 'login', 'getconfig', 'logout' ]
      },
      configall => {
        seq => [ 'login', 'getconfigall', 'logout' ]
      }
    }

## Command-line Options

**`--help`**
Display command-line options summary.

**`--trigger=MATCHID`**
Manually trigger event with MATCHID as defined in the `logfiles` configuration
section. You must provide at least the source hostname using the `--host`
option.

**`--host=HOST`**
Provides source hostname of a manually triggered event.

**`--user=USER`**
Provides username for a manually triggered event. Can be omitted, in that case
`unknown` is used instead.

**`--msg=MESSAGE`**
Provides commit message for a manually triggered event.

**`--force`**
Force RCS commit even when there's no change in the configuration (after
filtering using the `ignoreline` target option). Note that when old and new
revision are *exactly* the same, no commit is created by RCS.

**`--nocheckin[=PATHNAME]`**
Do not perform RCS check in after successfully retrieving configuration from a
device. When no PATHNAME is defined, the file is just left in the directory it
was downloaded to. When directory is specified, the file is moved there. When
filename is specified, the file is renamed into it. This should only be used
when manually triggering with the `--trigger` option.

**`--nomangle`**
Do not perform configuration file transformations prescribed in the target
config.

**`--initonly`**
Initialize and then exit immediately, this is useful for verifying basic
configuration validity.

**`--watchonly`**
Observe logfiles, log or display all message, but do not act upon any triggers.
This is most useful with `--devel` to verify that the program is seeing
log entries coming in. When matching log entry is received, additional info
is written to log.

**`--onlyuser=USER`**
Process only changes done by specified user, everything else will be ignored.
This is intended for troubleshooting.

**`--heartbeat[=SECONDS]`**
Enable heartbeat message logging. Default period is 300 seconds, different
number can be specified. Disabled by default.

**`--log=LOGID`**
Only specified log is processed, the rest is ignored.

**`--match=STRING`**
Try to match supplied string and exit. When there is match, the target, match_id
and all named capture groups are displayed. This is useful when designing
regular expressions for matching logfile entries.

**`--debug`**
Raises loglevel to DEBUG, which means debugging info will go to the log.

**`--devel`**
Enables development mode: loglevel is set to DEBUG, log goes to STDOUT
instead of file and the script does not detach from controlling terminal.

## To Do

* Fork the processing part. At this moment the processing blocks the entire
  program, which means that it's quite unsuitable for high traffic uses.
* Implement "automatic refresh" -- this feature would on regular basis try to
  refresh devices with too old configs in repository. This would probably
  necessitate some kind of hostname storage so that the program know where to go
  to for the refresh.
