require(data.table)
require(Rcpp)
require(ggplot2)

nextTime = function(n, rateParameter) {
  return(sapply(1:n,function(i) -log(1.0 - runif(1)) / rateParameter))
}

# Randomly calculate message interarrivals using Poisson processes
messages = data.table("Interarrival" = nextTime(1000,1/10))
# Sum up interarrivals to get timestamps for each message
messages[,Timestamp:=cumsum(Interarrival)]

# Assigning each message a constant service time.  You could use a distribution here
serviceTime=5
messages[,serviceTime := serviceTime]

# Lets randomly increase the service time for some of the messages to simulate jitter
messages[runif(n=10, min=0, max=.N),serviceTime := runif(n=.N, min=90, max=100)]

messages[,responseTime := calculateResponseTime(Timestamp, serviceTime)]

ggplot(messages, aes(x=Timestamp, y=responseTime))+
  geom_point(color="cornflowerblue")+
  gtheme()+
  ylab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10), limits=c(0,150))

ggplot(messages, aes(x=responseTime))+
  stat_ecdf(color="cornflowerblue")+
  gtheme()+
  ylab("Percentile")+
  xlab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))



# Calculate the latency difference between each message
messages[order(Timestamp), latencyDiff:=c(0,diff(responseTime))]

ggplot(messages[latencyDiff>0], aes(x=latencyDiff)) +
  stat_ecdf()+
  gtheme()+
  coord_cartesian(ylim=c(0.8,1))+
  ylab("Percentile")+
  xlab("Latency Delta")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))

# Identify all messages having "high" latency
messages[,highLatency := responseTime > 25]

# Identify contiguous sets of high latency messages using a run length encoding (see data.table ?rleid)
messages[,burstIdx := rleid(highLatency)]

# Mark messages which participated in a burst that contained an abnormal latencyDiff (service time). 
# Max latency diff should in theory be the service time, given two messages arriving at exactly the same time 
messages[,`Caused by Jitter` := max(latencyDiff, na.rm=T) > serviceTime,by=burstIdx]


ggplot(messages, aes(x=responseTime, color=`Caused by Jitter`)) +
  stat_ecdf()+
  gtheme()+
  ylab("Percentile")+
  xlab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))+
  scale_color_manual(values=c('cornflowerblue', 'green4'))

#filter to only high latency messages
highLatencyMessages = messages[highLatency == TRUE]