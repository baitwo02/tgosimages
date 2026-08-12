#include <errno.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/net/ethernet.h>
#include <zephyr/net/icmp.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/sys/printk.h>

static const uint8_t virtio_mac[] = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x57 };
static struct net_if *eth_iface;
static struct net_icmp_ctx ping_ctx;
static bool ping_passed;

static void find_eth_iface(struct net_if *iface, void *user_data)
{
	ARG_UNUSED(user_data);

	const struct net_linkaddr *link_addr = net_if_get_link_addr(iface);

	if (eth_iface == NULL &&
	    net_if_l2(iface) == &NET_L2_GET_NAME(ETHERNET) &&
	    link_addr != NULL &&
	    link_addr->len == sizeof(virtio_mac) &&
	    memcmp(link_addr->addr, virtio_mac, sizeof(virtio_mac)) == 0) {
		eth_iface = iface;
	}
}

static int configure_ipv4(void)
{
	struct in_addr addr;
	struct in_addr netmask;
	struct net_if_addr *ifaddr;

	net_if_foreach(find_eth_iface, NULL);
	if (eth_iface == NULL) {
		printk("ZEPHYR_NET: virtio ethernet interface not ready\n");
		return -ENODEV;
	}

	if (net_addr_pton(AF_INET, "192.0.2.2", &addr) < 0) {
		return -EINVAL;
	}

	if (net_addr_pton(AF_INET, "255.255.255.0", &netmask) < 0) {
		return -EINVAL;
	}

	ifaddr = net_if_ipv4_addr_add(eth_iface, &addr, NET_ADDR_MANUAL, 0);
	if (ifaddr == NULL) {
		printk("ZEPHYR_NET: failed to add IPv4 address\n");
		return -EIO;
	}

	net_if_ipv4_set_netmask_by_addr(eth_iface, &addr, &netmask);
	net_if_up(eth_iface);
	printk("ZEPHYR_NET: interface up at 192.0.2.2\n");

	return 0;
}

static enum net_verdict handle_echo_reply(struct net_icmp_ctx *ctx,
					  struct net_pkt *pkt,
					  struct net_icmp_ip_hdr *ip_hdr,
					  struct net_icmp_hdr *icmp_hdr,
					  void *user_data)
{
	ARG_UNUSED(ctx);
	ARG_UNUSED(pkt);
	ARG_UNUSED(icmp_hdr);
	ARG_UNUSED(user_data);

	if (ip_hdr->family != AF_INET) {
		return NET_CONTINUE;
	}

	if (!ping_passed) {
		ping_passed = true;
		printk("ZEPHYR_LINUX_VIRTIO_NET_PASS peer=192.0.2.1 protocol=icmp\n");
	}

	return NET_OK;
}

static int send_ping(uint16_t sequence)
{
	struct net_sockaddr_in dst = {
		.sin_family = AF_INET,
	};
	struct net_icmp_ping_params params = {
		.identifier = 0x1234,
		.sequence = sequence,
		.tc_tos = 0,
		.priority = 0,
		.data = NULL,
		.data_size = 16,
	};

	if (net_addr_pton(AF_INET, "192.0.2.1", &dst.sin_addr) < 0) {
		return -EINVAL;
	}

	return net_icmp_send_echo_request(&ping_ctx, eth_iface,
					  (struct net_sockaddr *)&dst, &params,
					  NULL);
}

int main(void)
{
	uint16_t sequence = 1;

	printk("ZEPHYR_NET: booted\n");

	while (configure_ipv4() != 0) {
		k_sleep(K_SECONDS(1));
	}

	if (net_icmp_init_ctx(&ping_ctx, AF_INET, NET_ICMPV4_ECHO_REPLY, 0,
			      handle_echo_reply) != 0) {
		printk("ZEPHYR_NET: failed to initialize ICMP context\n");
		return -EIO;
	}

	while (true) {
		if (!ping_passed) {
			int ret = send_ping(sequence++);

			if (ret != 0) {
				printk("ZEPHYR_NET: ping send failed ret=%d\n",
				       ret);
			}
		}

		k_sleep(K_SECONDS(1));
	}

	return 0;
}
