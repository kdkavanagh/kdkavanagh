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


