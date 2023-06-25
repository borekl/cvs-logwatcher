#==============================================================================
# Logfiles configuration and handling
#==============================================================================

package CVSLogwatcher::Logfile;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

use IO::Async::FileStream;

has id => ( is => 'ro', required => 1 );
has file => ( is => 'ro', required => 1 );
has matchre => ( is => 'ro', required => 1 );

sub match ($self, $l)
{
  my $re = $self->matchre;
  $l =~ /$re/;
  return ($+{host}, $+{user}, $+{msg});
}

# attach a logfile watcher to an IO::Async event loop (supplied in the argument)
sub watch ($self, $loop, $cmd)
{
  my $logid = $self->id;
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;

  # open logfile for reading
  open my $logh,  '<', $self->file or die "Cannot open logfile '$logid' ($!)";

  # create new FileStream instance
  my $fs = IO::Async::FileStream->new(

    read_handle => $logh,
    filename => $self->file,

    on_initial => sub {
      my ($self2) = @_;
      $self2->seek_to_last( "\n" );
    },

    on_read => sub {
      my ($self2, $buffref) = @_;
      while( $$buffref =~ s/^(.*\n)// ) {
        my $l = $1;
        # if --watchonly is active, display the line
        $logger->info("[cvs/$logid] $l") if $cmd->watchonly;
        # match line
        my ($host, $user, $msg) = $self->match($l);
        next unless $host;
        # find target
        my $target = $cfg->find_target($logid, $host);
        if(!$target) {
          $logger->warn(
            "[cvs] No target found for match from '$host' in source '$logid'"
          );
          next;
        }
        # finish if --watchonly
        next if $cmd->watchonly;
        # finish when --onlyuser specified and not matched
        if($cmd->onlyuser && $cmd->onlyuser ne $user) {
          $logger->info("[cvs/$logid] Skipping user $user\@$host (--onlyuser)");
          next;
        }
        # start processing
        CVSLogwatcher::Host->new(
          target => $target,
          name => $host,
          msg => $msg,
          who => $user ? $user : 'unknown',
          cmd => $cmd,
        )->process;
      }
      return 0;
    }
  );

  # attatch to event loop
  $loop->add($fs);
  $logger->info(
    sprintf('[cvs] Started observing %s (%s)', $self->file, $logid)
  );
}

1;
