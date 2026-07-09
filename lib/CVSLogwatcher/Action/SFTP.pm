#==============================================================================
# Talking to remote hosts using SFTP
#==============================================================================

package CVSLogwatcher::Action::SFTP;

use v5.36;
use Moo;

use Feature::Compat::Try;
use Net::SFTP::Foreign;

use CVSLogwatcher::Config;

has target => ( is => 'ro', required => 1 );

#-------------------------------------------------------------------------------
sub run ($self, $host, @rest)
{
  my $main_cfg = CVSLogwatcher::Config->instance;
  my $cfg = $self->target->config->{sftp};
  my $logger = $main_cfg->logger;
  my $tag = $host->tag;

  # open stderr filehandle for ssh and send it to blackhole
  open(my $stderr, '>', '/dev/null') or die 'Unable to open /dev/null';

  # establish SFTP connection
  my $sftp = Net::SFTP::Foreign->new(
    $host->name,
    user => $cfg->{user},
    password => $main_cfg->repl->replace($cfg->{password}),
    stderr_fh => $stderr,
    more => [
      -o => 'PubKeyAuthentication=no',
      -o => 'PreferredAuthentications=password',
      -o => 'StrictHostKeyChecking=no',
      -o => 'UserKnownHostsFile=/dev/null',
    ],
  );
  $sftp->die_on_error('Unable to connect to ' . $host->name);
  $logger->info(sprintf('[%s] Connected to %s', $tag, $host->name));

  # list target directory and select file to download
  my $dir = $sftp->ls($cfg->{cd});
  my $file_to_get;

  $sftp->die_on_error('Unable to list directory on ' . $host->name);

  for my $candidate ($cfg->{files}->@*) {
    if(grep { $candidate eq $_->{filename}  } @$dir) {
      $file_to_get = $candidate;
      last;
    }
  }

  # abort if no file to download was found
  if(!$file_to_get) {
    die(sprintf(
      "File %s does not exist on %s\n",
      join(' or ', $cfg->{files}->@*), $host->name
    ));
  }

  # log selected file
  $logger->info(sprintf(
    '[%s] Selected file %s for download', $tag, $file_to_get
  ));

  # change directory
  $sftp->setcwd($cfg->{cd});
  $sftp->die_on_error('Unable to cd to ' . $cfg->{cd} . ' on ' . $host->name);

  # get the file, the local file is stored in the temp directory and for the
  # filename the hostname of remote host is used
  my $local_dir = CVSLogwatcher::Config->instance->tempdir;
  my $local_file = $local_dir->child($file_to_get);

  $logger->info(sprintf(
    '[%s] Receiving %s -> %s', $tag, $file_to_get, $local_file)
  );

  $sftp->get($file_to_get, $local_file);
  $sftp->die_on_error('Failed to receive file %s ' . $local_file);

  # wrap the file with CVSL::File instance and return
  return CVSLogwatcher::File->new(file => $local_file, target => $self->target);
}

1;
