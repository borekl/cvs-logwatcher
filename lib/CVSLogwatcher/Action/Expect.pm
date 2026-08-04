#==============================================================================
# Talking to remote hosts using the Expect module
#==============================================================================

package CVSLogwatcher::Action::Expect;

use v5.36;
use Moo;

use Feature::Compat::Try;
use Expect;

use CVSLogwatcher::Config;
use CVSLogwatcher::Repl;
use CVSLogwatcher::Misc;
use CVSLogwatcher::File;
use CVSLogwatcher::Logger;

has target => ( is => 'ro', required => 1 );
has spawn => ( is => 'lazy' );
has sleep => ( is => 'lazy' );

sub _build_sleep ($self) { $self->target->{expect}{sleep} // 1 };

sub _build_spawn ($self) {
  $self->target->config->{expect}{spawn} // die "No expect 'spawn' line defined";
}

#------------------------------------------------------------------------------
# Return task by its name; FIXME more configuration checks needed
sub get_task ($self, $task = undef)
{
  my $cfg = $self->target->config->{expect};

  # if task not specified, use default task
  $task = $cfg->{deftask} // undef unless $task;

  # if task still not defined, throw exception
  die 'No task specified' unless $task;

  # return either task identification or the content of the task itself with
  # taskname prepended as the first list element
  if(wantarray) {
    return ($task, $cfg->{tasks}{$task});
  } else {
    return $task;
  }
}

#------------------------------------------------------------------------------
# Execute specified task (or default task if not specified). Returns list
# of files that were created during executing this task.
sub run ($self, $host, $task = undef)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = CVSLogwatcher::Logger->instance->prefix($host->tag);
  my @files;

  # create local Repl instance
  my $repl = $cfg->repl->clone->add_value(
    '%H' => $host->host_nodomain,
    '%h' => $host->name
  );

  # get the spawn string
  my $spawn = $repl->replace($self->spawn);

  # get sequence of chats to perform
  my ($task_name, $task_def) = $self->get_task($task);
  die 'Wrong or undefined task' unless $task_def;
  my @chats = $task_def->{seq}->@*;
  my $suffix = $task_def->{suffix} // undef;

  if(@chats) {
    $logger->info(
      'Running task "%s" with %d chats', $task_name, scalar(@chats)
    );
    $logger->debug('Chats: %s', join(', ', @chats));
  } else {
    $logger->fatal('Task "%s" has no chats, aborting', $task_name);
    return ();
  }

  # establish a connection with the remote host
  $logger->debug('Spawning Expect instance (%s)', $spawn);
  my $exh = Expect->spawn($spawn) or do {
    $logger->fatal('Failed to spawn Expect instance');
    return ();
  };
  $exh->log_stdout(0);
  $exh->restart_timeout_upon_receive(1);
  $exh->match_max(8192);

  try {

    # iterate over all chats in the task
    foreach my $chid (@chats) {
      my $chat = $self->target->config->{expect}{chats}{$chid};

      # iterate over chat lines
      my $line_count = 1;
      foreach my $chline (@$chat) {
        my ($look, $resp, $log, $prompt) = @$chline;
        $logger->debug(
          'Chat %s %d/%d', $chid, $line_count, scalar(@$chat)
        );

        # hide passwords, make CR visible
        my $resp_cloaked = $resp;
        $resp_cloaked = '***' if $look =~ /password/i;
        $resp_cloaked = '[CR]' if $resp eq "\r";

        # open transcript of the session
        if($log && $log ne '-') {
          $log = $repl->replace($log);
          $exh->log_file($log, 'w') or die "Failed to open file '$log'";
          push(@files, $log);
          $logger->info('Logfile opened: %s', $log);
        }

        # wait for expected string to arrive from remote
        $logger->debug(
          'Expect string(%d): %s', $line_count, $repl->replace($look)
        );
        $exh->expect(
          $cfg->config->{config}{expmax} // 300, '-re', $repl->replace($look)
        ) or die;
        my @g = $exh->matchlist;
        $logger->debug(
          'Expect receive(%d): %s', $line_count, $exh->match()
        );
        $logger->debug(
          'Expect groups(%d): %s', $line_count, join(',', @g)
        ) if @g;

        # close log if the log filename is '-'
        if($log && $log eq '-') {
          $logger->info('Closing logfile');
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
        $logger->debug(
          'Expect send(%d): %s', $line_count, $repl->replace($resp_cloaked)
        );
        $exh->print($repl->replace($resp));

        # keep count of lines
        $line_count++;
      }
    }

  } catch ($e) {
    $logger->error('Expect failed');
    $logger->debug('Failure reason is: %s', $e);
  }

  sleep($self->sleep) if $self->sleep;
  $exh->soft_close() if $exh;

  return map {
    CVSLogwatcher::File->new(file => $_, target => $self->target)
  } @files;
}

1;
