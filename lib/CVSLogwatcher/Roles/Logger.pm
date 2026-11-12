package CVSLogwatcher::Roles::Logger;

# this role adds logger attribute with instance that works as a logger;
# by default, this supplies an empty logger that does nothing

use Moo::Role;
use CVSLogwatcher::DummyLogger;

# logger method, default is DummyLogger, which does nothing; supply instance
# of Logger to do the real thing
has logger => (
  is => 'ro',
  default => sub { CVSLogwatcher::DummyLogger->new },
);

1;
