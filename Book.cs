namespace Lending
{
    public class Book
    {
        public string Isbn { get; set; }
        public string Title { get; set; }
        public string Author { get; set; }
        public int? HoldCount { get; set; }
        public bool IsReferenceOnly { get; set; }
    }
}
