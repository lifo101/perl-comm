XModem Perl Class
====

This is a very simple XModem class that supports sending and receiving 128 and 1024 byte packets. XModem is not widely used anymore but there are uses for it, (eg: in the networking world). I made this class when I couldn't find any other implementation on the web that would allow me to transfer files
between Cisco routers and switches.

This class requires the use of two file handles (INPUT and OUTPUT) that it uses to communicate with the remote client. I use this with Expect, and interestingly enough you can use the Expect object directly as both the INPUT and OUTPUT handles for this to work. 

Examples
====

These examples require X/Zmodem commands to be installed.

Sending
----

```perl
use XModem;
use IPC::Open2;
use FileHandle;

my $file = shift || 'file.txt';
my $pid = open2(my $IN=new FileHandle, my $OUT=new FileHandle, "rz -q -X -c -a recv.txt");
$OUT->autoflush(1);

my $xm = new XModem($IN, $OUT, verbose => 1);
$xm->sendfile($file) or die "Error: $@\n";
```    

Receiving
----

```perl
use XModem;
use IPC::Open2;
use FileHandle;

my $file = shift || 'file.txt';
my $pid = open2(my $IN=new FileHandle, my $OUT=new FileHandle, "sz -q -k -X $file 2>/dev/null");
$OUT->autoflush(1);

my $xm = new XModem($IN, $OUT, verbose => 1);
print "Bytes received: " . $xm->getfile('recv.txt', ascii => 1) . "\n" or die "Error: $@\n";
```
