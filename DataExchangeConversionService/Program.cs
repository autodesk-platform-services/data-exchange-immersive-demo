using DataExchangeConversionService.Models;
using DataExchangeConversionService.Options;
using DataExchangeConversionService.Services;

var builder = WebApplication.CreateBuilder(args);
// Timestamps go out as "2026-09-10T12:04:12Z" rather than in .NET's default form — see
// Iso8601UtcConverter. ConversionService registers the same converter on the serializer it uses
// for metadata.json.
builder.Services
    .AddControllers()
    .AddJsonOptions(options => options.JsonSerializerOptions.Converters.Add(new Iso8601UtcConverter()));
builder.Services.Configure<Options>(builder.Configuration.GetSection(Options.SectionName));
builder.Services.AddScoped<ConversionService>();
builder.Services.AddCors();

var app = builder.Build();
app.UseCors(policy => policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();
app.Run();
