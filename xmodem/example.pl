use strict;
use warnings;
use IPC::Open2;
use FileHandle;
use XModem;

# This is just for testing. Normally you might use this in combination with file handles
# from an Expect object that is connected to a remote switch or router.
# setup filehandles to a local process that will send/receive the file via the xmodem protocol.
my $file = shift || 'file.txt';
my $pid = open2(my $IN=new FileHandle, my $OUT=new FileHandle, "rz -q -X -c -a recv.txt");		# RECV
#my $pid = open2(my $IN=new FileHandle, my $OUT=new FileHandle, "sz -q -k -X $file 2>/dev/null");	# SEND
$OUT->autoflush(1);

my $xm = new XModem($IN, $OUT, verbose => 1);
$xm->sendfile($file) or die "Error: $@\n";								# SEND
#print "Bytes received: " . $xm->getfile('recv.txt', ascii => 1) . "\n" or die "Error: $@\n";		# RECV

