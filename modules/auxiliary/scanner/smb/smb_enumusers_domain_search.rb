##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary

  # Exploit mixins should be called first
  include Msf::Exploit::Remote::SMB
  include Msf::Exploit::Remote::SMB::Client::Authenticated
  include Msf::Exploit::Remote::DCERPC

  # Scanner mixin should be near last
  include Msf::Auxiliary::Scanner
  include Msf::Auxiliary::Report

  def initialize
  super(
    'Name'  => 'SMB Domain User Enumeration',
    'Version' =>  '$Revision $',
    'Description' =>  'Enumerate if any of the users in the USERS file are
logged into the remote systems. Any found users are stored in the DB.
(notes -t smb.enumusers_domain_search ),'
    'Author'    =>  [ 'Josh Abraham <jabra[at]praetorian.com>', ],
    'References'  =>
    [ [ 'URL',  'http://msdn.microsoft.com/en-us/library/aa370669%28VS.85%29.aspx'  ] ],
    'License' =>  MSF_LICENSE
  )

  register_options(
    [
      OptPath.new('USERS',   [ true, "Path to a file containing a list of users to search.",'']),
    ],self.class)

  deregister_options('RPORT', 'RHOST')

  end

  def parse_value(resp, idx)
    #val_length  = resp[idx,4].unpack("V")[0]
    idx += 4
    #val_offset = resp[idx,4].unpack("V")[0]
    idx += 4
    val_actual = resp[idx,4].unpack("V")[0]
    idx += 4
    value = resp[idx,val_actual*2]
    idx += val_actual * 2

    idx += val_actual % 2 * 2 # alignment

    return value,idx
  end

  def parse_netwkstaenumusersinfo(resp)
    accounts = [ Hash.new() ]

    idx = 20
    count = resp[idx,4].unpack("V")[0] # wkssvc_NetWkstaEnumUsersInfo -> Info -> PtrCt0 -> User() -> Ptr -> Max Count
    idx += 4

    1.upto(count) do
      # wkssvc_NetWkstaEnumUsersInfo -> Info -> PtrCt0 -> User() -> Ptr -> Ref ID
      idx += 4 # ref id name
      idx += 4 # ref id logon domain
      idx += 4 # ref id other domains
      idx += 4 # ref id logon server
    end

    1.upto(count) do
      # wkssvc_NetWkstaEnumUsersInfo -> Info -> PtrCt0 -> User() -> Ptr -> ID1 max count

      account_name,idx	= parse_value(resp, idx)
      logon_domain,idx	= parse_value(resp, idx)
      other_domains,idx	= parse_value(resp, idx)
      logon_server,idx	= parse_value(resp, idx)

      accounts << {
        :account_name => account_name,
        :logon_domain => logon_domain,
        :other_domains => other_domains,
        :logon_server => logon_server
      }
    end

    accounts
  end

  def run_host(ip)

    users = []
    File.open(datastore['USERS'], 'rb').each do |str|
      users.push(str.chomp)
    end

    [[139, false], [445, true]].each do |info|

      datastore['RPORT'] = info[0]
      datastore['SMBDirect'] = info[1]

      begin
        connect()
        smb_login()

        uuid = [ '6bffd098-a112-3610-9833-46c3f87e345a', '1.0' ]

        handle = dcerpc_handle(
          uuid[0], uuid[1], 'ncacn_np', ["\\wkssvc"]
        )
        begin
          dcerpc_bind(handle)
          stub = NDR.uwstring("\\\\" + ip) +	# Server Name
          NDR.long(1) +						# Level
          NDR.long(1) +						# Ctr
          NDR.long(rand(0xffffffff)) +	# ref id
          NDR.long(0) +						# entries read
          NDR.long(0) +						# null ptr to user0

          NDR.long(0xffffffff) +			# Prefmaxlen
          NDR.long(rand(0xffffffff)) +	# ref id
          NDR.long(0)							# null ptr to resume handle

          dcerpc.call(2,stub)

          resp = dcerpc.last_response ? dcerpc.last_response.stub_data : nil

          accounts = parse_netwkstaenumusersinfo(resp)
          accounts.shift
          if datastore['VERBOSE']
            accounts.each do |x|
              print_status ip + " : " + x[:logon_domain] + "\\" + x[:account_name] +
              "\t(logon_server: #{x[:logon_server]}, other_domains: #{x[:other_domains]})"
            end
          else
            print_status "#{ip} : #{accounts.collect{|x| x[:logon_domain] + "\\" + x[:account_name]}.join(", ")}"
          end

          found_accounts = []
          accounts.each do |x|
            comp_user = x[:logon_domain] + "\\" + x[:account_name]
            found_accounts.push(comp_user.scan(/[[:print:]]/).join) unless found_accounts.include?(comp_user.scan(/[[:print:]]/).join)
          end

          users.each do |user|
            found_accounts.each do |comp_user|
              if user.to_s == comp_user.to_s
                print_good("#{ip} - Found user: #{user}")
                report_note(
                  :host	=> ip,
                  :proto	=> 'tcp',
                  :port	=> rport,
                  :type	=> 'smb.enumusers_domain_search',
                  :data	=> { :user => user },
                  :update => :unique_data
                )
              end
            end
          end

        rescue ::Rex::Proto::SMB::Exceptions::ErrorCode => e
          print_line("UUID #{uuid[0]} #{uuid[1]} ERROR 0x%.8x" % e.error_code)
        rescue ::Exception => e
          print_line("UUID #{uuid[0]} #{uuid[1]} ERROR #{$!}")
        end

        disconnect()
        return

      rescue ::Exception
        print_line($!.to_s)
      end
    end
  end
end
