
for ip in 9.11.120.{200..254} 9.11.121.{1..100}; do
  arping -c 1 -W 1 -I ens3 $ip &>/dev/null || echo "FREE: $ip"
done
``


GET FIRST FREE IP : 
VIP=$(for i in {200..254}; do arping -c1 -W1 -I ens3 9.11.120.$i &>/dev/null || { echo 9.11.120.$i; break; }; done)
echo $VIP