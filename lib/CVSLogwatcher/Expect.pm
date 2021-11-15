#==============================================================================
# Talking to remote hosts using the Expect module
#==============================================================================

package CVSLogwatcher::Expect;

use Moo;
use v5.10;
use warnings;
use strict;
use experimental 'signatures';

use Feature::Compat::Try;
use Expect;

use CVSLogwatcher::Config;
use CVSLogwatcher::Repl;
use CVSLogwatcher::Misc;

has config => ( is => 'ro', required => 1 );
has spawn => ( is => 'lazy' );
has sleep => ( is => 'lazy' );

sub _build_sleep ($self) { $self->config->{sleep} // 1 };

sub _build_spawn ($self) {
  $self->config->{spawn} // die "No expect 'spawn' line defined";
}

#------------------------------------------------------------------------------
# Return task by its name; FIXME more configuration checks needed
sub get_task ($self, $task = undef)
{
  my $cfg = $self->config;

  # if task not specified, use default task
  $task = $cfg->{deftask} // undef unless $task;

  # if task still not defined, throw exception
  die 'No task specified' unless $task;

  # return either task identification or the content of the task itself with
  # taskname prepended as the first list element
  if(wantarray) {
    return ($task, @{$cfg->{tasks}{$task}});
  } else {
    return $task;
  }
}

#------------------------------------------------------------------------------
# Execute specified task (or default task if not specified). Returns list
# of files that were created during executing this task.
sub run_task ($self, $host, $task = undef)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $h = host_strip_domain($host);
  my @files;

  # create local Repl instance
  my $repl = $cfg->repl->clone->add_value(
    '%H' => $h,
    '%h' => $host
  );

  # get logger
  my $logger = $cfg->logger;

  # get the spawn string
  my $spawn = $repl->replace($self->spawn);

  # get sequence of chats to perform
  my ($task_name, @chats) = $self->get_task($task);
  if(@chats) {
    $cfg->logger->info(sprintf(
      '[cvs/%s] Running task "%s" with %d chats', $h, $task_name, scalar(@chats)
    ));
    $cfg->logger->debug(sprintf(
      '[cvs/%s] Chats: %s', $h, join(', ', @chats)
    ));
  } else {
    $cfg->logger->fatal(
      sprintf('[cvs/%s] Task "%s" has no chats, aborting', $h)
    );
    return ();
  }

  # establish a connection with the remote host
  $cfg->logger->debug(
    sprintf('[cvs/%s] Spawning Expect instance (%s)', $h, $spawn)
  );
  my $exh = Expect->spawn($spawn) or do {
    $logger->fatal("[cvs/$h] Failed to spawn Expect instance");
    return ();
  };
  $exh->log_stdout(0);
  $exh->restart_timeout_upon_receive(1);
  $exh->match_max(8192);

  try {

    # iterate over all chats in the task
    foreach my $chid (@chats) {
      my $chat = $self->config->{chats}{$chid};

      # iterate over chat lines
      my $line_count = 1;
      foreach my $chline (@$chat) {
        my ($look, $resp, $log, $prompt) = @$chline;
        $cfg->logger->debug(sprintf(
          '[cvs/%s] Chat %s %d/%d', $h, $chid, $line_count, scalar(@$chat)
        ));

        # hide passwords, make CR visible
        my $resp_cloaked = $resp;
        $resp_cloaked = '***' if $look =~ /password/i;
        $resp_cloaked = '[CR]' if $resp eq "\r";

        # open transcript of the session
        if($log && $log ne '-') {
          $log = $repl->replace($log);
          $exh->log_file($log, 'w') or die "Failed to open file '$log'";
          push(@files, $log);
          $logger->info("[cvs/$h] Logfile opened: ", $log);
        }

        # wait for expected string to arrive from remote
        $logger->debug(sprintf(
          '[cvs/%s] Expect string(%d): %s',
          $h, $line_count, $repl->replace($look)
        ));
        $exh->expect(
          $cfg->tailparam('expmax') // 300, '-re', $repl->replace($look)
        ) or die;
        my @g = $exh->matchlist;
        $logger->debug(sprintf(
          '[cvs/%s] Expect receive(%d): %s', $h, $line_count, $exh->match()
        ));
        $logger->debug(sprintf(
          '[cvs/%s] Expect groups(%d): %s', $h, $line_count, join(',', @g)
        )) if @g;

        # close log if the log filename is '-'
        if($log && $log eq '-') {
          $logger->info("[cvs/$h] Closing logfile");
          $exh->log_file(undef);
        }

        # make capture groups available for further matching in the expect
        # strings
        $repl->add_capture_groups(@g);

        # establish prompt token %P for further matching
        $repl->add_value('%P' => quotemeta($repl->replace($prompt))) if $prompt;

        # additional delay
        sleep($self->sleep) if $self->sleep;

        # send response
        $logger->debug(sprintf(
          '[cvs/%s] Expect send(%d): %s',
          $h, $line_count, $repl->replace($resp_cloaked)
        ));
        $exh->print($repl->replace($resp));

        # keep count of lines
        $line_count++;
      }
    }

  } catch ($e) {
    $logger->error("[cvs/$h] Expect failed for host $host");
    $logger->debug("[cvs/$h] Failure reason is: ", $e);
  }

  sleep($self->sleep) if $self->sleep;
  $exh->soft_close() if $exh;

  return @files;
}

1;
