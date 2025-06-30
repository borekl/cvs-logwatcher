#=============================================================================
# Module to interface with command-line options.
#=============================================================================

package CVSLogwatcher::Cmdline;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

use Getopt::Long qw(GetOptionsFromString);

# command-line option attributes
has debug      =>  ( is => 'rwp' );
has devel      =>  ( is => 'rwp' );
has trigger    =>  ( is => 'rwp' );
has host       =>  ( is => 'rwp' );
has user       =>  ( is => 'rwp' );
has msg        =>  ( is => 'rwp' );
has file       =>  ( is => 'rwp' );
has force      =>  ( is => 'rwp', default => 0 );
has nocheckin  =>  ( is => 'rwp' );
has mangle     =>  ( is => 'rwp', default => 1 );
has initonly   =>  ( is => 'rwp' );
has log        =>  ( is => 'rwp' );
has watchonly  =>  ( is => 'rwp' );
has task       =>  ( is => 'rwp' );
has onlyuser   =>  ( is => 'rwp' );
has heartbeat  =>  ( is => 'rwp' );
has match      =>  ( is => 'rwp' );

# flags
has interactive => ( is => 'rwp', default => 0 );

#-----------------------------------------------------------------------------
# build function
sub BUILD ($self, $args)
{
  my @options = (
    'trigger=s'   => sub { $self->_set_trigger(lc $_[1]) },
    'host=s'      => sub { $self->_set_host(lc $_[1]) },
    'user=s'      => sub { $self->_set_user($_[1]) },
    'msg=s'       => sub { $self->_set_msg($_[1]) },
    'file=s'      => sub { $self->_set_file($_[1]) },
    'force'       => sub { $self->_set_force($_[1]) },
    'nocheckin:s' => sub { $self->_set_nocheckin($_[1]) },
    'mangle!'     => sub { $self->_set_mangle($_[1]) },
    'initonly'    => sub { $self->_set_initonly($_[1]) },
    'debug'       => sub { $self->_set_debug($_[1]) },
    'devel'       => sub { $self->_set_debug($_[1]), $self->_set_devel($_[1]) },
    'log=s'       => sub { $self->_set_log($_[1]) },
    'watchonly'   => sub { $self->_set_watchonly($_[1]) },
    'task=s'      => sub { $self->_set_task($_[1]) },
    'onlyuser=s'  => sub { $self->_set_onlyuser($_[1]) },
    'heartbeat:i' => sub { $self->_set_heartbeat($_[1] || 300) },
    'match=s'     => sub {
                       $self->_set_match($_[1]);
                       $self->_set_interactive(1);
                     },
    'help|?'      => sub { $self->help; exit(0); }
  );

  # if invoked with 'cmdline' argument, use the value of that argument to parse
  # options from; this is useful for tests
  if(defined $args->{cmdline}) {
    if(!GetOptionsFromString($args->{cmdline}, @options)) { exit(1) }
  }

  # otherwise parse options from @ARGV as usual
  elsif(!GetOptions(@options)) { exit(1) }
}

#-----------------------------------------------------------------------------
# Display help message
sub help
{
  print <<EOHD;

Usage: cvs-logwatcher.pl [options]

  --help             get this information text
  --trigger=MATCHID  trigger processing as if MATCHID matched
  --host=HOST        define host for --trigger or limit processing to it
  --user=USER        define user for --trigger
  --msg=MSG          define message for --trigger
  --file=FILE        check-in supplied file
  --force            force check-in when using --trigger
  --nocheckin[=FILE] do not perform repository check in with --trigger
  --nomangle         do not perform config text transformations
  --debug            set loglevel to debug
  --devel            development mode, implies --debug
  --initonly         init everything and exit
  --watchonly        only observe logfiles
  --onlyuser=USER    only changes by specified user are processed
  --heartbeat[=N]    enable heartbeat logging every N seconds (default 300)
  --log=LOGID        only process this log
  --match=STRING     try to match supplied string, output result and exit

EOHD
}

#-----------------------------------------------------------------------------
# Dump the commandline options state as a list of formatted lines
sub dump ($self)
{
  my @out;

  push(@out, sprintf('trigger:   %s', $self->trigger // '--'));
  push(@out, sprintf('host:      %s', $self->host // '--'));
  push(@out, sprintf('user:      %s', $self->user // '--'));
  push(@out, sprintf('msg:       %s', $self->msg // '--'));
  push(@out, sprintf('file:      %s', $self->file // '--'));
  push(@out, sprintf('force:     %s', $self->force ? 'true' : 'false'));
  if(defined $self->nocheckin) {
    push(@out, sprintf('nocheckin: %s', $self->nocheckin ? $self->nocheckin : 'true' ));
  } else {
    push(@out, 'nocheckin: false');
  }
  push(@out, sprintf('mangle:    %s', $self->mangle ? 'true' : 'false'));
  push(@out, sprintf('initonly:  %s', $self->initonly ? 'true' : 'false'));
  push(@out, sprintf('log:       %s', $self->log // '--'));
  push(@out, sprintf('task:      %s', $self->task // '--'));
  push(@out, sprintf('watchonly: %s', $self->watchonly ? 'true' : 'false'));
  push(@out, sprintf('heartbeat: %s', $self->heartbeat ? $self->heartbeat : 'disabled'));
  push(@out, sprintf('match:     %s', $self->match // '--'));
  push(@out, sprintf('debug:     %s', $self->debug ? 'true' : 'false'));
  push(@out, sprintf('devel:     %s', $self->devel ? 'true' : 'false'));

  return @out;
}

1;
