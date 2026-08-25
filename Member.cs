using System;

namespace Lending
{
    public class Member
    {
        public string MemberId { get; set; }
        public string Name { get; set; }
        public DateTime JoinedDate { get; set; }
        public bool IsSuspended { get; set; }
        public decimal OutstandingFees { get; set; }
    }
}
