using DataExchangeViewingService.Options;
using DataExchangeViewingService.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
builder.Services.Configure<Options>(builder.Configuration.GetSection(Options.SectionName));
builder.Services.AddScoped<IConversionService, ConversionService>();

var app = builder.Build();
app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();
app.Run();
