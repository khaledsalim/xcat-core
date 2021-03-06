# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::boottarget;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use Storable qw(dclone);
use Sys::Syslog;
use Thread qw(yield);
use POSIX qw(WNOHANG nice);
use xCAT::Table;
use xCAT::Utils;
use xCAT::TableUtils;
use xCAT::MsgUtils;
use xCAT::Template;
#use xCAT::Postage;
use Data::Dumper;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use File::Path;
use File::Copy;



sub handled_commands
{
    return {
            mknetboot => "nodetype:os=(boottarget)|(target)|(bt)",
	    mkinstall => "nodetype:os=(boottarget)|(target)|(bt)"
            };
}

sub preprocess_request
{
    my $req      = shift;
    my $callback = shift;
    #if already preprocessed, go straight to request
    if ($req->{_xcatpreprocessed}->[0] == 1) { return [$req]; }

    if ($req->{command}->[0] eq 'copycd')
    {    #don't farm out copycd
        return [$req];
    }

    #my $stab = xCAT::Table->new('site');
    #my $sent;
    #($sent) = $stab->getAttribs({key => 'sharedtftp'}, 'value');
    my @entries =  xCAT::TableUtils->get_site_attribute("sharedtftp");
    my $site_entry = $entries[0];
    unless (   defined($site_entry)
            and ( $site_entry =~ /no/i or $site_entry =~ /0/))
    {

        #unless requesting no sharedtftp, don't make hierarchical call
        return [$req];
    }

    my %localnodehash;
    my %dispatchhash;
    my $nrtab = xCAT::Table->new('noderes');
    my $nrents = $nrtab->getNodesAttribs($req->{node},[qw(tftpserver servicenode)]);
    foreach my $node (@{$req->{node}})
    {
        my $nodeserver;
        my $tent = $nrents->{$node}->[0]; #$nrtab->getNodeAttribs($node, ['tftpserver']);
        if ($tent) { $nodeserver = $tent->{tftpserver} }
        unless ($tent and $tent->{tftpserver})
        {
            $tent = $nrents->{$node}->[0]; #$nrtab->getNodeAttribs($node, ['servicenode']);
            if ($tent) { $nodeserver = $tent->{servicenode} }
        }
        if ($nodeserver)
        {
            $dispatchhash{$nodeserver}->{$node} = 1;
        }
        else
        {
            $localnodehash{$node} = 1;
        }
    }
    my @requests;
    my $reqc = {%$req};
    $reqc->{node} = [keys %localnodehash];
    if (scalar(@{$reqc->{node}})) { push @requests, $reqc }

    foreach my $dtarg (keys %dispatchhash)
    {    #iterate dispatch targets
        my $reqcopy = {%$req};    #deep copy
        $reqcopy->{'_xcatdest'} = $dtarg;
	$reqcopy->{_xcatpreprocessed}->[0] = 1;
        $reqcopy->{node} = [keys %{$dispatchhash{$dtarg}}];
        push @requests, $reqcopy;
    }
    return \@requests;
}

sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = undef;
    my $arch     = undef;
    my $path     = undef;
    return mknetboot($request, $callback, $doreq);
}

sub mknetboot
{
    my $req      = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $nodes    = @{$request->{node}};
    my @args     = @{$req->{arg}};
    my @nodes    = @{$req->{node}};
    my $ostab    = xCAT::Table->new('nodetype');
 
    my $installroot = xCAT::TableUtils->getInstallDir();
    my $tftpdir = xCAT::TableUtils->getTftpDir();

    my %donetftp=();
    my %oents = %{$ostab->getNodesAttribs(\@nodes,[qw(os arch profile)])};
    my $restab = xCAT::Table->new('noderes');
    my $bptab  = xCAT::Table->new('bootparams',-create=>1);
    my $hmtab  = xCAT::Table->new('nodehm');
    my $ttab   = xCAT::Table->new('boottarget');

    foreach $node (@nodes)
    {
        my $ent = $oents{$node}->[0]; #ostab->getNodeAttribs($node, ['os', 'arch', 'profile']);
        unless ($ent->{os} and $ent->{profile})
        {
            $callback->(
                        {
                         error     => ["Insufficient nodetype entry for $node"],
                         errorcode => [1]
                        }
                        );
            next;
        }
	
        my $profile = $ent->{profile};
    	($tent) = $ttab->getAttribs({'bprofile' => $profile}, 'kernel', 'initrd', 'kcmdline'); #TODO: coalesce these queries into one Table query, speed it up
	if(! defined($tent)){
		my $msg =  "$profile in nodetype table was not defined in boottarget table";
		$callback->({
			error => ["$msg"],
	                errorcode => [1]
		});
	}
	$kernel = $tent->{kernel};
	$initrd = $tent->{initrd};
	$kcmdline = $tent->{kcmdline};
	#TODO: big todo, cheap and rapid, but should be more like esx.pm implementation, i.e. more scalable
	while ($kcmdline =~ /#NODEATTRIB:([^:#]+):([^:#]+)#/) {
	    my $natab = xCAT::Table->new($1);
	    my $naent = $natab->getNodeAttribs($node,[$2]);
	    my $naval = $naent->{$2};
        $kcmdline =~ s/#NODEATTRIB:([^:#]+):([^:#]+)#/$naval/;
    }
	while ($kcmdline =~ /#TABLE:([^:#]+):([^:#]+):([^:#]+)#/) {
        my $tabname = $1;
        my $keyname = $2;
        my $colname = $3;
        if ($2 =~ /THISNODE/ or $2 =~ /\$NODE/) {
    	    my $natab = xCAT::Table->new($tabname);
	        my $naent = $natab->getNodeAttribs($node,[$colname]);
	        my $naval = $naent->{$colname};
            $kcmdline =~ s/#TABLE:([^:#]+):([^:#]+):([^:#]+)#/$naval/;
        } else {
		    my $msg =  "Table key of $2 not yet supported by boottarget mini-template";
    		$callback->({
    			error => ["$msg"],
    	                errorcode => [1]
    		});
            
        }
    }

	if($initrd eq ''){
        	$bptab->setNodeAttribs(
                      $node,
                      {
                       kernel => $kernel,
                       initrd => '',
                       kcmdline => $kcmdline
                      }
                     );
	}else{
        	$bptab->setNodeAttribs(
                      $node,
                      {
                       kernel => $kernel,
                       initrd => $initrd,
                       kcmdline => $kcmdline
                      }
                     );
	}
    }

}

1;
