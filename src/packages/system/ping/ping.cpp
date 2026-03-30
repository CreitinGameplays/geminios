#include <iostream>
#include <string>
#include <vector>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/ip_icmp.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/time.h>
#include <csignal>
#include <cmath>
#include "network.h"
#include "signals.h"

volatile bool g_running = true;
void sig_handler(int) { g_running = false; g_stop_sig = 1; }

struct icmp_packet {
    struct icmphdr hdr;
    char msg[64];
};

unsigned short checksum(void *b, int len) {
    unsigned short *buf = (unsigned short *)b;
    unsigned int sum = 0;
    unsigned short result;
    for (sum = 0; len > 1; len -= 2) sum += *buf++;
    if (len == 1) sum += *(unsigned char *)buf;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    result = ~sum;
    return result;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: ping <destination>\n";
        return 1;
    }

    std::string dest = argv[1];
    std::string ip_str = ResolveDNS(dest);
    
    // If resolve failed, try treating it as IP
    if (ip_str.empty()) ip_str = dest;
    
    // Check if valid IP
    struct sockaddr_in addr;
    if (inet_pton(AF_INET, ip_str.c_str(), &addr.sin_addr) <= 0) {
        std::cerr << "ping: unknown host " << dest << "\n";
        return 1;
    }
    
    int sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (sock < 0) {
        perror("ping: socket (requires root)");
        return 1;
    }

    // Set timeout
    struct timeval tv_out;
    tv_out.tv_sec = 1;
    tv_out.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv_out, sizeof(tv_out));

    signal(SIGINT, sig_handler);

    std::cout << "PING " << dest << " (" << ip_str << ") 56(84) bytes of data.\n";

    int seq = 1;
    int received = 0;
    
    struct sockaddr_in r_addr;
    socklen_t addr_len = sizeof(r_addr);
    
    while (g_running) {
        icmp_packet pckt;
        memset(&pckt, 0, sizeof(pckt));
        pckt.hdr.type = ICMP_ECHO;
        pckt.hdr.un.echo.id = getpid();
        pckt.hdr.un.echo.sequence = seq;
        for (int i = 0; i < sizeof(pckt.msg) - 1; i++) pckt.msg[i] = i + '0';
        pckt.msg[sizeof(pckt.msg) - 1] = 0;
        pckt.hdr.checksum = checksum(&pckt, sizeof(pckt));

        addr.sin_family = AF_INET;
        inet_pton(AF_INET, ip_str.c_str(), &addr.sin_addr);

        struct timeval start, end;
        gettimeofday(&start, NULL);

        if (sendto(sock, &pckt, sizeof(pckt), 0, (struct sockaddr*)&addr, sizeof(addr)) <= 0) {
            perror("ping: sendto");
        }

        char buf[1024];
        if (recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr*)&r_addr, &addr_len) > 0) {
            gettimeofday(&end, NULL);
            double elapsed = (end.tv_sec - start.tv_sec) * 1000.0 + (end.tv_usec - start.tv_usec) / 1000.0;
            
            struct iphdr *ip = (struct iphdr*)buf;
            // Verify ICMP Reply
            struct icmphdr *icmp = (struct icmphdr*)(buf + (ip->ihl * 4));
            
            if (icmp->type == ICMP_ECHOREPLY) { // Only reply
                std::cout << "64 bytes from " << ip_str << ": icmp_seq=" << seq 
                          << " ttl=" << (int)ip->ttl << " time=" << elapsed << " ms\n";
                received++;
            }
        } else {
             // std::cout << "Request timeout for icmp_seq " << seq << "\n";
        }

        seq++;
        sleep(1);
    }

    std::cout << "\n--- " << dest << " ping statistics ---\n";
    std::cout << (seq - 1) << " packets transmitted, " << received << " received, "
              << ((seq - 1 - received) * 100) / (seq > 1 ? seq - 1 : 1) << "% packet loss\n";

    close(sock);
    return 0;
}
