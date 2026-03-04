#!/usr/bin/env perl
use strict;
use warnings;

my $env_file = "$FindBin::Bin/../.env" if eval { require FindBin; 1 };
$env_file //= ".env";

# Read .env
my %env;
if (open my $fh, '<', $env_file) {
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;
        if (/^(\w+)=(.*)$/) {
            $env{$1} = $2;
        }
    }
    close $fh;
}

my $host = $env{SSH_HOST} or die "SSH_HOST not found in .env\n";
my $user = $env{SSH_USER} or die "SSH_USER not found in .env\n";
my $pass = $env{SSH_PASSWORD} or die "SSH_PASSWORD not found in .env\n";

my $key_path = "$ENV{HOME}/.ssh/ai_server_key";

# Generate SSH key if it doesn't exist
if (! -f $key_path) {
    print "Generating SSH key at $key_path...\n";
    system("ssh-keygen", "-t", "ed25519", "-f", $key_path, "-N", "", "-C", "ai-server-key") == 0
        or die "ssh-keygen failed: $!\n";
} else {
    print "Key already exists at $key_path, skipping generation.\n";
}

# Copy public key to remote server
print "Copying public key to $user\@$host...\n";
my $pub_key = do {
    open my $fh, '<', "$key_path.pub" or die "Can't read public key: $!\n";
    local $/;
    my $k = <$fh>;
    chomp $k;
    $k;
};

my $cmd = qq{sshpass -p '$pass' ssh -o StrictHostKeyChecking=no $user\@$host "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"};
system($cmd);
if ($? != 0) {
    print "sshpass failed -- trying ssh-copy-id instead...\n";
    system(qq{sshpass -p '$pass' ssh-copy-id -i $key_path.pub -o StrictHostKeyChecking=no $user\@$host});
    if ($? != 0) {
        die "Could not copy key. Install sshpass: brew install sshpass or hudochenkov/sshpass/sshpass\n";
    }
}

# Update .env with key path
print "Updating .env with SSH_KEY_PATH...\n";
my $updated = 0;
my @lines;
if (open my $fh, '<', $env_file) {
    @lines = <$fh>;
    close $fh;
}

for (@lines) {
    if (/^SSH_KEY_PATH=/) {
        $_ = "SSH_KEY_PATH=$key_path\n";
        $updated = 1;
    }
}
push @lines, "SSH_KEY_PATH=$key_path\n" unless $updated;

open my $fh, '>', $env_file or die "Can't write .env: $!\n";
print $fh @lines;
close $fh;

# Verify connection with key
print "\nVerifying key-based login...\n";
system("ssh", "-i", $key_path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "$user\@$host", "echo 'SSH key auth works!'");
if ($? == 0) {
    print "\nDone! You can now connect with: ssh -i $key_path $user\@$host\n";
} else {
    print "\nKey was generated but auth verification failed. You may need to copy the key manually.\n";
}
