using DataExchangeViewingService.Options;
using DataExchangeViewingService.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
builder.Services.Configure<Options>(builder.Configuration.GetSection(Options.SectionName));
builder.Services.AddScoped<IConversionService, ConversionService>();
builder.Services.AddCors();

var app = builder.Build();
// Allow browsers to call the service directly (the web app is served from a different origin).
app.UseCors(policy => policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();
app.Run();
