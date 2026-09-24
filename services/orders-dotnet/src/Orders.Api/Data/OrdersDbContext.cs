using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Orders.Api.Data;

public sealed partial class OrdersDbContext(DbContextOptions<OrdersDbContext> options) : DbContext(options)
{
    public DbSet<Order> Orders => Set<Order>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Order>(o =>
        {
            o.ToTable("orders");
            o.HasKey(x => x.Id);
            o.Property(x => x.TenantId).HasMaxLength(64);
            o.Property(x => x.CustomerId).HasMaxLength(64);
            o.Property(x => x.Status).HasMaxLength(16);
            o.Property(x => x.Currency).HasMaxLength(3);
            o.Property(x => x.TotalAmount).HasPrecision(19, 4);
            o.HasIndex(x => new { x.TenantId, x.CreatedAt });
            o.HasMany(x => x.Lines).WithOne().HasForeignKey(l => l.OrderId).OnDelete(DeleteBehavior.Cascade);
        });
        modelBuilder.Entity<OrderLine>(l =>
        {
            l.ToTable("order_lines");
            l.HasKey(x => x.Id);
            l.Property(x => x.ProductName).HasMaxLength(200);
            l.Property(x => x.UnitPrice).HasPrecision(19, 4);
        });

        // snake_case columns, like every other service's schema
        foreach (var property in modelBuilder.Model.GetEntityTypes().SelectMany(e => e.GetProperties()))
        {
            property.SetColumnName(SnakeCase().Replace(property.Name, "$1_$2").ToLowerInvariant());
        }
    }

    [GeneratedRegex("([a-z0-9])([A-Z])")]
    private static partial Regex SnakeCase();
}

/// <summary>Used by `dotnet ef migrations add` only.</summary>
public sealed class OrdersDbContextFactory : IDesignTimeDbContextFactory<OrdersDbContext>
{
    public OrdersDbContext CreateDbContext(string[] args) =>
        new(new DbContextOptionsBuilder<OrdersDbContext>().UseNpgsql("Host=localhost;Database=orders").Options);
}
