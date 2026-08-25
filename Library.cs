using System;
using System.Collections.Generic;
using System.Linq;

namespace Lending
{
    public class Library
    {
        private readonly List<Loan> _loans = new List<Loan>();
        private readonly List<Book> _books = new List<Book>();
        private readonly List<Member> _members = new List<Member>();

        public void AddLoan(Loan loan) { _loans.Add(loan); }
        public void AddBook(Book book) { _books.Add(book); }
        public void AddMember(Member member) { _members.Add(member); }

        public IEnumerable<Loan> LoansFor(string memberId)
        {
            return _loans.Where(l => l.MemberId == memberId);
        }

        public IEnumerable<Loan> Overdue(DateTime asOf)
        {
            return _loans.Where(l => l.ReturnedDate == null && l.DueDate < asOf);
        }

        public Book FindBook(string isbn)
        {
            return _books.FirstOrDefault(b => b.Isbn == isbn);
        }

        public Member FindMember(string memberId)
        {
            return _members.FirstOrDefault(m => m.MemberId == memberId);
        }
    }
}
