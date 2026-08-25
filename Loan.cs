using System;

namespace Lending
{
    public class Loan
    {
        public string Isbn { get; set; }
        public string BookTitle { get; set; }
        public string MemberId { get; set; }
        public DateTime CheckedOutDate { get; set; }
        public DateTime DueDate { get; set; }
        public DateTime? ReturnedDate { get; set; }
        public int RenewalCount { get; set; }
    }
}
