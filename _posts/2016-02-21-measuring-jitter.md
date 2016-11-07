---
title: Measuring Jitter - Work In Progress
excerpt: "Using R to separate high latency caused by queuing from that caused randomly by the operating system, garbage collections, power savings, etc in massive datasets"
modified: 2016-02-21
tags: [performance, R, jitter, visualization]
---
# Generating the Dummy Data
First we generate a dummy set of messages.  Common queuing theory states that messages typically arrive to a system at rates following a Poisson distribution, and as such, we use a Poisson process to model the interarrival times of our fake messages.  We then perform a cumulative sum on these arrival rates to calculate the arrival time of each message in our data set.
{% highlight R %}
require(data.table)
require(Rcpp)
require(ggplot2)

nextTime = function(n, rateParameter) {
  return(sapply(1:n,function(i) -log(1.0 - runif(1)) / rateParameter))
}

# Randomly calculate 1000 message interarrivals using Poisson processes
messages = data.table("Interarrival" = nextTime(1000,1/10))
# Sum up interarrivals to get timestamps for each message
messages[,Timestamp:=cumsum(Interarrival)]
{% endhighlight %}

Next, we assign a service time to each message.  We randomly pick 10 messages and assign them a latency between 90 and 100, to simulate some jitter in our system.

{% highlight R %}
# Assigning each message a constant service time.  You could use a distribution here
serviceTime=5
messages[,serviceTime := serviceTime]

# Lets randomly increase the service time for some of the messages to simulate jitter
messages[runif(n=10, min=0, max=.N),serviceTime := runif(n=.N, min=90, max=100)]
{% endhighlight %}

Now that we have the service times calculated for each message, we need to work through the list of messages in order and calculate the response times.  We consider our system to be an M/M/1 queuing system, such that we must fully process the current message before beginning to process the subsequent message.

Unfortunately, R is terribly slow that these iterative processes that cannot be vectorized.  As a result, we write our response time calculator in C++ and link it to R with Rcpp.

{% highlight C++ %}
#include <Rcpp.h>
using namespace Rcpp;

// [[Rcpp::export]]
NumericVector calculateResponseTime(NumericVector timestamps, NumericVector serviceTimes) {
  NumericVector responseTimes(timestamps.size());

  //Prime the pump
  responseTimes[0] = serviceTimes[0];

  for(int i=1; i<timestamps.size(); i++) {
    double prevTimeOut = timestamps[i-1]+responseTimes[i-1];
    double ts = timestamps[i];
    double serviceTime = serviceTimes[i];

    //We can't start processing this message until the previous one has left our system
    double timeToStartProcessing = std::max(prevTimeOut, ts);
    double timeOut = timeToStartProcessing + serviceTime;

    //Calculate the final response time
    responseTimes[i] = timeOut - ts;
  }

  return responseTimes;
}
{% endhighlight %}

And then assign response times to each message in R.

{% highlight R %}
messages[,responseTime := calculateResponseTime(Timestamp, serviceTime)]
{% endhighlight %}

This gives us a timeseries of messages that looks like this:
<figure>
	<img src="/images/jitterTimeseries.png">
</figure>

Summarizing the response times gives us the following cumulative distribution:
<figure>
	<img src="/images/jitterComboCdf.png">
</figure>

# Identifying Jitter

## Latency Delta
Now that we have our dataset that resembles a real queuing system, we can focus on determining which messages had a high latency as the result of jitter, and which messages had a high latency simply due to queuing in the system.

First, we order the messages by time, and calculate the delta in the latencies between each message.  We also mark messages which had a "high" latency, in this case any message with a response time greater than 25.
{% highlight R %}
# Calculate the latency difference between each message
messages[order(Timestamp), latencyDiff:=c(0,diff(responseTime))]

# Identify all messages having "high" latency
messages[,highLatency := responseTime > 25]
{% endhighlight %}

Latency delta is a good indicator of system jitter.  Consider the worst case scenario - two messages that arrive at the system at effectively the same time.  The first message begins processing, and the second message is queued.  The first message will have a response time equal to the service time.  The second message begins processing when the first is complete and has a response time equal to twice the service time (since it spent 1 unit of service time queued).  The latency delta for these two messages is equal to the service time.

Any message that shows an increase in latency greater than the service time of the system can be considered an "abnormal latency delta".  If the system is hit with many messages arriving at a fast rate, response times will increase due to queuing, but the latency delta should be capped at the service time of the application.

Latency delta may be < 0, characterizing a return from high latencies to normal latencies.  

If the application is idle and not processing any messages when a new message arrives, the latency difference is expected to be ~0 (assuming the previous message from long ago had a normal latency).

More generally, the latency delta should fall in the range (<0, service time).

Plotting the distribution of latency deltas, we observe that most messages with a positive latency delta have a delta of less than 5, equal to our service time. We also observe that about 2% of our messages are the first to encounter jitter of ~95.  This knowledge can help us identify the source of the jitter, since many jitter-inducing routines (e.g context swaps, SMI interrupts, etc) have a constant effect on latency.
<figure>
	<img src="/images/latencyDiffCdf.png">
</figure>

## Periods of High and Low Latency
Unfortunately latency delta only indicates the **first** message that was affected by jitter.  Consider something like a garbage collection in Java.  During a garbage collection, the process grinds to a halt, and incoming messages are queued.  When the application wakes up, the first message will have a high latency delta from the previous message, but each subsequent message received during the GC will have a low (or negative) latency delta relative to the previous message, as the application drains its queue.

To account for this, we group contiguous sets of messages having high or low latency together using a run-length-encoding to create unique groups of messages.  For each group, we check if a message exists in that group with a latency delta higher than the service time of the system, and mark all messages in that group as being "affected by jitter".
{% highlight R %}
# Identify contiguous sets of high latency messages using a run length encoding (see data.table ?rleid)
messages[,burstIdx := rleid(highLatency)]

# Mark messages which participated in a burst that contained an abnormal latencyDiff (service time).
# Max latency diff should in theory be the service time, given two messages arriving at exactly the same time
messages[,`Caused by Jitter` := max(latencyDiff, na.rm=T) > serviceTime,by=burstIdx]
{% endhighlight %}

We can now separate our latency distribution in to messages that were affected by jitter, and those that were not, to see the effect of jitter on our system.
<figure>
	<img src="/images/jitterSeparated.png">
</figure>

We can also plot only high latency messages caused by queuing against high latency messages caused by jitter.
<figure>
	<img src="/images/highLatSeparated.png">
</figure>

# Further Reading & Resources

## Graph code
{% highlight R %}
# Timeseries
ggplot(messages, aes(x=Timestamp, y=responseTime))+
  geom_point(color="cornflowerblue")+
  ylab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10), limits=c(0,150))

# Response Time CDF
ggplot(messages, aes(x=responseTime))+
  stat_ecdf(color="cornflowerblue")+
  ylab("Percentile")+
  xlab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))

# Latency Delta CDF
ggplot(messages[latencyDiff>0], aes(x=latencyDiff)) +
  stat_ecdf(color="cornflowerblue")+
  coord_cartesian(ylim=c(0.8,1))+
  ylab("Percentile")+
  xlab("Latency Delta")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))

# Jitter separate CDF
ggplot(messages, aes(x=responseTime, color=`Caused by Jitter`)) +
  stat_ecdf()+
  ylab("Percentile")+
  xlab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))+
  scale_color_manual(values=c('cornflowerblue', 'green4'))

# High Latency Messages, separated
ggplot(messages[highLatency == TRUE], aes(x=responseTime, color=`Caused by Jitter`)) +
  stat_ecdf()+
  ylab("Percentile")+
  xlab("Response Time")+
  scale_y_continuous(breaks=number_ticks(10))+
  scale_x_continuous(breaks=number_ticks(10))+
  scale_color_manual(values=c('cornflowerblue', 'green4'))

{% endhighlight %}
