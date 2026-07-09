using DataExchangeConversionService.Options;
using DataExchangeConversionService.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
builder.Services.Configure<Options>(builder.Configuration.GetSection(Options.SectionName));
builder.Services.AddScoped<ConversionService>();
builder.Services.AddCors();

var app = builder.Build();
app.UseCors(policy => policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod());
app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();
app.Run();
