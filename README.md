# TCPDUMP_with_LOG_MONITOR

NO WARRANTY


1. run below commands on both units:
    
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    config # mkdir -p /var/tmp/captures
    config # chmod 766 /var/tmp/captures
    config # cd /var/tmp/captures
    captures # vim ringdump_any.pl
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    
    2. Go here: https://raw.githubusercontent.com/tnsy/TCPDUMP_with_LOG_MONITOR/master/ringdump.pl > copy all text and paste it to ringdump_any.pl file opened in point 1.
    
    [!] This is our internal script that comes with no warranty [!]
    
    3. Save the file and run below commands:
    
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # chmod +x ringdump_any.pl 
    # ./ringdump_any.pl 
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    
    4. Fill in the questions as below:
    
    A. Box that is currently STANDBY:
    
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Enter the desired vlan else enter "any" to capture on all vlans:
    any
    
    Enter the desired packet capture filter e.g ((host 10.110.110.249 and host 10.100.100.50) and port 80):
    host 2.2.2.2 and host 2.2.2.1
    
    Enter the log message to stop the packet capture:
    Active for traffic group /Common/traffic-group-1.
    capturing to /var/tmp/captures using the following interfaces and filters:
       any: host 2.2.2.2 and host 2.2.2.1
    does this look right?  [y/n]: y
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
